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

  # --- Redis modules (e.g. ["RediSearch", "RedisJSON", "Bloom",
  # "TimeSeries"]) — resolved here as their own maps, not inside
  # _redis_raw, because Layer 3c's eviction-policy default depends on
  # "does this request enable RediSearch" (same sibling-reference reason
  # as the maps above).
  #
  # Name/duplicate/topology/SKU validation is enforced HARD by the redis
  # module (variable validation + lifecycle preconditions). This template
  # only normalises the shape and adds early, per-request warnings (see
  # the redis-modules-* checks below).
  #
  # A request whose redis_modules / redis_module_args is not the right
  # JSON shape (e.g. a string instead of an array) is NOT silently
  # dropped: it's replaced with a sentinel value the module's own
  # validation is guaranteed to reject, so plan fails hard, and the
  # redis-modules-valid-shape check names the offending request.
  _redis_modules_invalid_shape_sentinel = ["INVALID-SHAPE: redis_modules must be a JSON array of module-name strings"]
  _redis_module_args_invalid_shape_sentinel = {
    "INVALID-SHAPE: redis_module_args must be a JSON object of module-name to string" = "x"
  }

  # Deliberately NO default.json fallback for modules (unlike every other
  # field): modules are create-time only, so a platform-wide default would
  # silently destroy and recreate EVERY existing cache in the environment
  # that doesn't list its own modules. Omitted/null always means "none".
  _instance_redis_modules = {
    for name, payload in local._requested_instances :
    name => (
      try(payload.instance.redis_modules, null) == null
      ? tolist([])
      : try(tolist(payload.instance.redis_modules), local._redis_modules_invalid_shape_sentinel)
    )
  }

  _instance_redis_module_args = {
    for name, payload in local._requested_instances :
    name => (
      try(payload.instance.redis_module_args, null) == null
      ? tomap({})
      : try(tomap(payload.instance.redis_module_args), local._redis_module_args_invalid_shape_sentinel)
    )
  }

  # lower-cased copies, only for the template's own checks and the
  # RediSearch eviction default below.
  _instance_redis_modules_lower = {
    for name, mods in local._instance_redis_modules :
    name => [for m in mods : try(lower(trimspace(m)), "")]
  }

  _instance_wants_redisearch = {
    for name, mods in local._instance_redis_modules_lower :
    name => contains(mods, "redisearch") || contains(mods, "search")
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

      # RediSearch requires NoEviction (Azure). When a request enables
      # RediSearch and doesn't set eviction_policy itself, default to
      # NoEviction instead of default.json's value, so a correct request
      # never trips the module's "forced NoEviction" warning. An explicit
      # conflicting eviction_policy is still passed through verbatim — the
      # module forces NoEviction and the redisearch-requires-noeviction
      # check below warns.
      eviction-policy = try(
        payload.instance.eviction_policy,
        local._instance_wants_redisearch[name] ? "NoEviction" : local._defaults_raw.eviction_policy
      )

      # --- Redis modules (create-time only — changing either forces the
      # instance to be replaced; see the module's README) ---
      redis-modules     = local._instance_redis_modules[name]
      redis-module-args = local._instance_redis_module_args[name]

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

############################################
# Redis modules — early, per-request warnings.
#
# These are ADVISORY (a check block can never block an apply). The hard
# enforcement lives in the redis module itself: variable validation on
# redis-modules / redis-module-args and lifecycle preconditions on
# azurerm_managed_redis.primary. These checks exist so a reviewer sees
# WHICH request file is wrong, by instance name, before reading the
# module's error.
############################################

locals {
  _redis_module_names_allowed = ["redisearch", "search", "redisjson", "json", "redisbloom", "bloom", "redistimeseries", "timeseries"]
  _redis_module_canonical_lower = {
    search = "redisearch", json = "redisjson", bloom = "redisbloom", timeseries = "redistimeseries"
  }

  _requests_with_invalid_redis_modules_shape = [
    for name, payload in local._requested_instances : name
    if(
      (try(payload.instance.redis_modules, null) == null ? false : !can(tolist(payload.instance.redis_modules))) ||
      (try(payload.instance.redis_module_args, null) == null ? false : !can(tomap(payload.instance.redis_module_args)))
    )
  ]

  _requests_with_invalid_redis_module_names = [
    for name, mods in local._instance_redis_modules_lower : name
    if !alltrue([for m in mods : contains(local._redis_module_names_allowed, m)])
  ]

  _requests_with_duplicate_redis_modules = [
    for name, mods in local._instance_redis_modules_lower : name
    if length(mods) != length(distinct([for m in mods : lookup(local._redis_module_canonical_lower, m, m)]))
  ]

  # Active geo-replication supports only RediSearch + RedisJSON.
  _requests_with_redis_modules_unsupported_by_active_active = [
    for name, mods in local._instance_redis_modules_lower : name
    if local._instance_topologies[name] == "DR-ActiveActive" && anytrue([
      for m in mods : contains(["redisbloom", "bloom", "redistimeseries", "timeseries"], m)
    ])
  ]

  # FlashOptimized_* supports only RedisJSON; EnterpriseFlash_* only
  # RediSearch + RedisJSON.
  _requests_with_redis_modules_unsupported_by_sku = [
    for name, mods in local._instance_redis_modules_lower : name
    if anytrue([
      for m in mods : (
        startswith(local._redis_raw[name].node-type, "FlashOptimized_") ? !contains(["redisjson", "json"], m) :
        startswith(local._redis_raw[name].node-type, "EnterpriseFlash_") ? !contains(["redisearch", "search", "redisjson", "json"], m) :
        false
      )
    ])
  ]

  # RediSearch + an explicitly requested eviction_policy other than
  # NoEviction: the module forces NoEviction, this makes it visible.
  _requests_with_redisearch_eviction_conflict = [
    for name, payload in local._requested_instances : name
    if local._instance_wants_redisearch[name] && coalesce(try(payload.instance.eviction_policy, null), "NoEviction") != "NoEviction"
  ]
}

check "redis-modules-valid-shape" {
  assert {
    condition     = length(local._requests_with_invalid_redis_modules_shape) == 0
    error_message = "Request(s) with a malformed redis_modules / redis_module_args: ${join(", ", local._requests_with_invalid_redis_modules_shape)}. redis_modules must be a JSON array of strings (e.g. [\"RediSearch\", \"RedisJSON\"]); redis_module_args must be a JSON object of module name to string. Plan will fail in the redis module for these requests."
  }
}

check "redis-modules-valid-names" {
  assert {
    condition     = length(local._requests_with_invalid_redis_module_names) == 0
    error_message = "Request(s) with an unknown module name in redis_modules: ${join(", ", local._requests_with_invalid_redis_module_names)}. Allowed (case-insensitive): RediSearch (or Search), RedisJSON (or JSON), RedisBloom (or Bloom), RedisTimeSeries (or TimeSeries). Plan will fail in the redis module for these requests."
  }
}

check "redis-modules-no-duplicates" {
  assert {
    condition     = length(local._requests_with_duplicate_redis_modules) == 0
    error_message = "Request(s) listing the same module twice in redis_modules (aliases count as the same module, e.g. \"Bloom\" and \"RedisBloom\"): ${join(", ", local._requests_with_duplicate_redis_modules)}. Plan will fail in the redis module for these requests."
  }
}

check "redis-modules-active-active-compatible" {
  assert {
    condition     = length(local._requests_with_redis_modules_unsupported_by_active_active) == 0
    error_message = "DR-ActiveActive request(s) with a module active geo-replication doesn't support: ${join(", ", local._requests_with_redis_modules_unsupported_by_active_active)}. Only RediSearch and RedisJSON can be used with DR-ActiveActive. Plan will fail in the redis module for these requests."
  }
}

check "redis-modules-sku-compatible" {
  assert {
    condition     = length(local._requests_with_redis_modules_unsupported_by_sku) == 0
    error_message = "Request(s) with a module their node_type doesn't support: ${join(", ", local._requests_with_redis_modules_unsupported_by_sku)}. FlashOptimized_* supports only RedisJSON; EnterpriseFlash_* supports only RediSearch and RedisJSON. Plan will fail in the redis module for these requests."
  }
}

check "redisearch-requires-noeviction" {
  assert {
    condition     = length(local._requests_with_redisearch_eviction_conflict) == 0
    error_message = "Request(s) enabling RediSearch with an explicit eviction_policy other than NoEviction: ${join(", ", local._requests_with_redisearch_eviction_conflict)}. Azure requires NoEviction (and EnterpriseCluster clustering) for RediSearch — the redis module forces both for this apply. Remove eviction_policy from the request, or set it to NoEviction."
  }
}
