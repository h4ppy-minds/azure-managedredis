locals {

  # --- Layer 1: global technical defaults + per-environment infra ---
  # default.json field names are unchanged (snake_case JSON, e.g.
  # "deployment_topology", "node_type") — this rewrite's kebab-case
  # convention applies to the Terraform variable/output surface (this
  # root's own `env` variable, and the redis module's variables/outputs),
  # NOT to the request-file/default.json schema itself. Renaming the JSON
  # schema would ripple into the wrapper-API mapping docs and every
  # existing request file for no benefit — scoped out deliberately.
  _defaults_raw = jsondecode(file("${path.module}/config/onboarding-files-redis/default.json"))
  _env_infra    = local._defaults_raw.environments[var.env]

  # --- Layer 2: one onboarding request per file ---
  _all_instances = {
    for f in fileset("${path.module}/config/onboarding-files-redis", "*.json") :
    f => jsondecode(file("${path.module}/config/onboarding-files-redis/${f}"))
    if f != "default.json"
  }

  _requested_instances = {
    for f, payload in local._all_instances :
    payload.instance.name => payload
    if payload.environment == var.env && payload.request_type != "delete"
  }

  _instance_name_counts = {
    for f, payload in local._all_instances :
    payload.instance.name => f...
    if payload.environment == var.env && payload.request_type != "delete"
  }
}

check "request-names-unique-per-environment" {
  assert {
    condition = alltrue([
      for name, files in local._instance_name_counts : length(files) == 1
    ])
    error_message = "Two or more onboarding request files for environment '${var.env}' share the same instance.name — only one will actually be applied, the rest silently disappear. Colliding names: ${join(", ", [for name, files in local._instance_name_counts : "${name} (${join(", ", files)})" if length(files) > 1])}."
  }
}

locals {
  # --- Layer 3: defaults -> env infra -> instance overrides, staged into
  # a map whose keys match the redis module's kebab-case variable names
  # 1:1 — this map is passed almost verbatim into each module "redis"
  # call in main.tf. Reading FROM the (unchanged, snake_case) JSON on the
  # right-hand side, writing TO kebab-case keys on the left is the
  # deliberate translation boundary between "what a request file says"
  # and "what the module expects."
  #
  # Every nested object (persistence) is merged FIELD BY FIELD, not with
  # a single merge() of the whole sub-object — see the module's own
  # README for why a partial override (e.g. just {"persistence": {"mode":
  # "AOF"}}) needs this instead of losing sibling defaults.
  _redis_raw = {
    for name, payload in local._requested_instances :
    name => {
      # --- Identity ---
      name                = payload.instance.name
      environment         = var.env
      resource-group-name = local._env_infra.resource_group_name

      location = try(payload.instance.location, local._env_infra.location)

      # --- Deployment topology (single settable knob) ---
      deployment-topology = try(payload.instance.deployment_topology, local._defaults_raw.deployment_topology)

      # --- Sizing — REQUIRED on the module now, so this must never
      # resolve to null. try() still guards against a request omitting
      # it; default.json.node_type is the fallback of last resort.
      node-type = try(payload.instance.node_type, local._defaults_raw.node_type)

      # --- Networking — always environment infra, never
      # instance-settable. The module now creates a private endpoint
      # unconditionally for every instance (no create-private-endpoint
      # toggle any more), so this is always required, not
      # best-effort. ---
      subnet-name              = try(local._env_infra.networking.subnet_name, null)
      vnet-name                = try(local._env_infra.networking.vnet_name, null)
      vnet-resource-group-name = try(local._env_infra.networking.vnet_resource_group_name, null)

      # DR-region networking — required whenever this instance's
      # deployment-topology creates a DR instance, since the module now
      # always gives the DR instance a private endpoint too (no more
      # "DR instance without a private endpoint" opt-in state). Still
      # read via try() so a genuinely missing dr_networking block in
      # default.json surfaces as a clear module-side check failure
      # rather than a Terraform "attribute not found" crash here.
      dr-subnet-name              = try(local._env_infra.dr_networking.subnet_name, null)
      dr-vnet-name                = try(local._env_infra.dr_networking.vnet_name, null)
      dr-vnet-resource-group-name = try(local._env_infra.dr_networking.vnet_resource_group_name, null)

      # No vnet-id / dr-vnet-id / DNS-zone fields any more — the module
      # no longer creates or links a private DNS zone (Infoblox handles
      # DNS resolution for these private endpoints outside Terraform).

      # --- Auth / TLS ---
      # client-protocol / public-network-access are not set here — the
      # module hard-locks both and rejects any other value.
      authorization-mode = try(payload.instance.authorization_mode, local._defaults_raw.authorization_mode)

      # --- Persistence (field-by-field) ---
      persistence-mode          = try(payload.instance.persistence.mode, local._defaults_raw.persistence.mode)
      persistence-rdb-frequency = try(payload.instance.persistence.rdb_frequency, local._defaults_raw.persistence.rdb_frequency)
      persistence-aof-frequency = try(payload.instance.persistence.aof_frequency, local._defaults_raw.persistence.aof_frequency)

      eviction-policy = try(payload.instance.eviction_policy, local._defaults_raw.eviction_policy)

      # --- Deletion protection ---
      deletion-protection-enabled = try(payload.instance.deletion_protection_enabled, local._defaults_raw.deletion_protection_enabled)

      # --- Geo-replication group name (DR-ActiveActive only) ---
      # ALWAYS a real string now, never null — Azure's API requires
      # geo_replication_group_name to actually be set on the database
      # when geo-replication is in effect; "Azure auto-generates one when
      # omitted" was incorrect and caused a real apply failure. A request
      # can still override it; the fallback is deterministic
      # (<name>-<env>-geo) rather than left to chance.
      geo-replication-group-name = try(
        payload.instance.geo_replication_group_name,
        "${payload.instance.name}-${var.env}-geo"
      )

      # --- Labels: application_id / lob are instance-level fields (NOT
      # nested under instance.tags). Carried through with underscore
      # prefixes since they're intermediate values Layer 4 still needs to
      # combine with topology/environment/managed_by before they become
      # the final `tags` map the module receives.
      _application_id = try(payload.instance.application_id, local._defaults_raw.default_application_id)
      _lob            = try(payload.instance.lob, null)
      _raw_tags       = try(payload.instance.tags, {})

      # --- Raw DR signal for Layer 4's dr-location derivation.
      _wants_dr = try(
        contains(["DR-ActivePassive", "DR-ActiveActive"], payload.instance.deployment_topology),
        contains(["DR-ActivePassive", "DR-ActiveActive"], local._defaults_raw.deployment_topology)
      )
    }
  }

  # --- Cross-region DR pairing ---
  _dr_pair_list = try(local._defaults_raw.dr_region_pairs, [])
  _dr_region_pairs = merge([
    for pair in local._dr_pair_list : {
      (pair[0]) = pair[1]
      (pair[1]) = pair[0]
    }
  ]...)

  # --- Layer 4: derive dr-location and tags — computable only AFTER
  # Layer 3's per-field merge.
  #
  # `topology`, `environment`, and `managed_by` are ALWAYS derived here
  # and never taken from the request file. Note: the module itself also
  # now preserves tags across updates via lifecycle { ignore_changes =
  # [tags] } — so this Layer 4 tag computation only actually takes effect
  # on an instance's FIRST apply. Changing tags in a request file for an
  # already-existing instance and re-applying will not update that
  # instance's tags; see the module's README "Tags are preserved across
  # updates" for the full tradeoff.
  redis = {
    for name, cfg in local._redis_raw :
    name => merge(cfg, {
      dr-location = cfg._wants_dr ? try(local._dr_region_pairs[cfg.location], null) : null

      tags = merge(
        { application_id = cfg._application_id },
        cfg._lob != null ? { lob = cfg._lob } : {},
        {
          for k, v in cfg._raw_tags : k => v
          if !contains(["application_id", "lob", "topology", "environment", "managed_by"], k)
        },
        {
          topology    = lower(cfg.deployment-topology)
          environment = var.env
          managed_by  = "terraform"
        }
      )
    })
  }
}

check "dr-requires-supported-region-pair" {
  assert {
    condition = alltrue([
      for name, cfg in local.redis : !cfg._wants_dr || cfg.dr-location != null
    ])
    error_message = "One or more DR requests picked a primary `location` with no supported DR secondary. Cross-region DR is currently only supported between the pairs listed in default.json's dr_region_pairs (today: ${join(", ", [for p in local._dr_pair_list : "${p[0]} <-> ${p[1]}"])}). Either change that instance's location to a supported primary, or ask the platform team to add a new pair to default.json.dr_region_pairs."
  }
}
