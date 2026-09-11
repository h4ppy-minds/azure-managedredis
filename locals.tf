locals {

  # --- Layer 1: global technical defaults + per-environment infra ---
  # default.json field names are unchanged (snake_case JSON) — the
  # kebab-case convention applies to the Terraform variable/output
  # surface only, not the request-file/default.json schema.
  #
  # environments.<env> now has default_location + a `regions` map keyed
  # by region name (e.g. "eastus2", "centralus"), each with its own
  # resource_group_name and networking block. Both primary and DR look up
  # whichever region they need from this SAME map — there's no more
  # separate/asymmetric "networking" (primary, flat) vs "dr_networking"
  # (DR, special-cased) shape. This is what actually lets a client
  # request centralus AS THE PRIMARY, not just as a DR target, and gives
  # DR its own resource group per Azure's standard one-resource-group-
  # per-region guidance (see the redis module's own README).
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
  # --- Layer 3a: resolve primary location, topology, and the DR-wanted
  # signal FIRST, as their own standalone maps. HCL object construction
  # cannot reference a sibling key of the SAME object literal being
  # built (no "a = 1, b = a" within one { } block) — computing these as
  # separate top-level locals, rather than as fields inside _redis_raw's
  # object literal below, is what lets the resource-group/networking
  # lookups in Layer 3b actually use "this instance's own location" as
  # a lookup key without a self-reference error.
  _instance_locations = {
    for name, payload in local._requested_instances :
    name => try(payload.instance.location, local._env_infra.default_location)
  }

  _instance_topologies = {
    for name, payload in local._requested_instances :
    name => try(payload.instance.deployment_topology, local._defaults_raw.deployment_topology)
  }

  _instance_wants_dr = {
    for name, topology in local._instance_topologies :
    name => contains(["DR-ActivePassive", "DR-ActiveActive"], topology)
  }

  # --- Cross-region DR pairing (global — which regions CAN pair at all) ---
  _dr_pair_list = try(local._defaults_raw.dr_region_pairs, [])
  _dr_region_pairs = merge([
    for pair in local._dr_pair_list : {
      (pair[0]) = pair[1]
      (pair[1]) = pair[0]
    }
  ]...)

  # --- Layer 3b: resolve DR location per instance, using the maps above.
  # Still a separate map from _redis_raw for the same self-reference
  # reason as Layer 3a.
  _instance_dr_locations = {
    for name, wants_dr in local._instance_wants_dr :
    name => wants_dr ? try(local._dr_region_pairs[local._instance_locations[name]], null) : null
  }
}

check "location-is-a-configured-region" {
  assert {
    condition = alltrue([
      for name, loc in local._instance_locations :
      contains(keys(try(local._env_infra.regions, {})), loc)
    ])
    error_message = "One or more requests picked a `location` that environment '${var.env}' has no regions entry for in default.json. Configured regions for this environment: ${join(", ", keys(try(local._env_infra.regions, {})))}. Either change that instance's location, or ask the platform team to add a regions entry for it."
  }
}

check "dr-location-is-a-configured-region" {
  assert {
    condition = alltrue([
      for name, dr_loc in local._instance_dr_locations :
      dr_loc == null || contains(keys(try(local._env_infra.regions, {})), dr_loc)
    ])
    error_message = "One or more DR requests resolved a dr_location that environment '${var.env}' has no regions entry for in default.json — the region pair exists globally (dr_region_pairs), but this environment hasn't been given resource_group_name/networking for it yet. Configured regions for this environment: ${join(", ", keys(try(local._env_infra.regions, {})))}."
  }
}

locals {
  # --- Layer 3c: defaults -> env infra -> instance overrides, staged
  # into a map whose keys match the redis module's kebab-case variable
  # names 1:1 — this map is passed almost verbatim into each module
  # "redis" call in main.tf.
  #
  # Every nested object (persistence) is merged FIELD BY FIELD, not with
  # a single merge() of the whole sub-object — see the module's own
  # README for why a partial override needs this instead of losing
  # sibling defaults.
  _redis_raw = {
    for name, payload in local._requested_instances :
    name => {
      # --- Identity ---
      name        = payload.instance.name
      environment = var.env

      location = local._instance_locations[name]

      # Resource group and networking are now looked up FROM location,
      # not a flat per-environment value — this is what makes centralus
      # (or any other configured region) work as a PRIMARY location, not
      # just as a DR target.
      resource-group-name      = local._env_infra.regions[local._instance_locations[name]].resource_group_name
      subnet-name              = local._env_infra.regions[local._instance_locations[name]].networking.subnet_name
      vnet-name                = local._env_infra.regions[local._instance_locations[name]].networking.vnet_name
      vnet-resource-group-name = local._env_infra.regions[local._instance_locations[name]].networking.vnet_resource_group_name

      # --- Deployment topology (single settable knob) ---
      deployment-topology = local._instance_topologies[name]

      dr-location = local._instance_dr_locations[name]

      # DR gets its OWN resource group/networking — looked up from
      # dr-location the same way primary's came from location — rather
      # than reusing primary's resource group. try() handles the
      # non-DR case where dr-location is null (no DR region to look up).
      dr-resource-group-name = try(
        local._env_infra.regions[local._instance_dr_locations[name]].resource_group_name, null
      )
      dr-subnet-name = try(
        local._env_infra.regions[local._instance_dr_locations[name]].networking.subnet_name, null
      )
      dr-vnet-name = try(
        local._env_infra.regions[local._instance_dr_locations[name]].networking.vnet_name, null
      )
      dr-vnet-resource-group-name = try(
        local._env_infra.regions[local._instance_dr_locations[name]].networking.vnet_resource_group_name, null
      )

      # No vnet-id / DNS-zone fields — the module no longer creates or
      # links a private DNS zone (Infoblox handles DNS resolution for
      # these private endpoints outside Terraform).

      # --- Sizing — REQUIRED on the module now, so this must never
      # resolve to null. try() still guards against a request omitting
      # it; default.json.node_type is the fallback of last resort.
      node-type = try(payload.instance.node_type, local._defaults_raw.node_type)

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
      # ALWAYS a real string, never null — Azure's API requires
      # geo_replication_group_name to actually be set when geo-replication
      # is in effect. A request can still override it; the fallback is
      # deterministic (<name>-<env>-geo) rather than left to chance.
      geo-replication-group-name = try(
        payload.instance.geo_replication_group_name,
        "${payload.instance.name}-${var.env}-geo"
      )

      # --- Labels: application_id / lob are instance-level fields (NOT
      # nested under instance.tags). Carried through with underscore
      # prefixes since Layer 4 still needs to combine them with
      # topology/environment/managed_by before they become the final
      # `tags` map the module receives.
      _application_id = try(payload.instance.application_id, local._defaults_raw.default_application_id)
      _lob            = try(payload.instance.lob, null)
      _raw_tags       = try(payload.instance.tags, {})
    }
  }

  # --- Layer 4: derive tags — the only thing left that needs the
  # per-field merge from Layer 3c to already exist.
  #
  # `topology`, `environment`, and `managed_by` are ALWAYS derived here
  # and never taken from the request file. Note: the module itself now
  # preserves tags across updates via lifecycle { ignore_changes = [tags] }
  # — so this computation only actually takes effect on an instance's
  # FIRST apply. See the module's README "Tags are preserved across
  # updates" for the full tradeoff.
  redis = {
    for name, cfg in local._redis_raw :
    name => merge(cfg, {
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
      for name, wants_dr in local._instance_wants_dr :
      !wants_dr || local._instance_dr_locations[name] != null
    ])
    error_message = "One or more DR requests picked a primary `location` with no supported DR secondary. Cross-region DR is currently only supported between the pairs listed in default.json's dr_region_pairs (today: ${join(", ", [for p in local._dr_pair_list : "${p[0]} <-> ${p[1]}"])}). Either change that instance's location to a supported primary, or ask the platform team to add a new pair to default.json.dr_region_pairs."
  }
}
