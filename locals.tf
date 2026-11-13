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

  # --- Layer 3b: resolve the PAIRED region per instance, using the maps
  # above. Resolved for EVERY request, not just DR topologies: every
  # primary gets a second private endpoint in its paired region (same
  # pattern as the org's PostgreSQL servers), and DR topologies also put
  # the DR instance there. Still a separate map from _redis_raw for the
  # same self-reference reason as Layer 3a.
  _instance_dr_locations = {
    for name, payload in local._requested_instances :
    name => try(local._dr_region_pairs[local._instance_locations[name]], null)
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
      # Conditional, not `dr_loc == null || contains(...)`: `||` does not
      # short-circuit on every Terraform/OpenTofu version, and contains()
      # errors on a null value — which every non-DR request has.
      dr_loc == null ? true : contains(keys(try(local._env_infra.regions, {})), dr_loc)
    ])
    error_message = "One or more requests resolved a paired region that environment '${var.env}' has no regions entry for in default.json — the region pair exists globally (dr_region_pairs), but this environment hasn't been given resource_group_name/networking for it yet, so the paired-region private endpoint (and any DR instance) has nowhere to go. Configured regions for this environment: ${join(", ", keys(try(local._env_infra.regions, {})))}."
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

      # The paired region gets its OWN resource group/networking — looked
      # up from dr-location the same way primary's came from location.
      # Used for the primary's paired-region private endpoint (every
      # topology) and, for DR topologies, the DR instance and its
      # endpoint. try() covers a location with no pair, which the
      # paired-region-is-supported check below reports.
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

      # --- HA and clustering policy — platform policy per topology
      # (redis module 0.5.0, local.defaults.topology-profile):
      #   STANDALONE        HA optional (default off), EnterpriseCluster
      #                     (NoCluster only as an explicit legacy pin on
      #                     caches created before 0.5.0)
      #   HA / DR-*         HA always on, EnterpriseCluster (default) or OSSCluster
      # Violations fail the plan in the module; the checks below name the
      # request.
      #
      # high_availability: only meaningful for STANDALONE. null = topology
      # default (off for STANDALONE, on for the rest).
      high-availability-enabled = try(payload.instance.high_availability, null)

      # Request value, else default.json's (EnterpriseCluster), else the
      # module's topology default (also EnterpriseCluster). A RediSearch
      # request that doesn't set it gets EnterpriseCluster (Azure
      # requirement), so it never trips the module's "forced" warning.
      # Create-time only: on an EXISTING instance a different value fails
      # the plan (module's clustering policy guard) instead of letting
      # azurerm wipe the database.
      clustering-policy = try(
        payload.instance.clustering_policy,
        local._instance_wants_redisearch[name] ? "EnterpriseCluster" : try(local._defaults_raw.clustering_policy, null)
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
      for name, dr_loc in local._instance_dr_locations : dr_loc != null
    ])
    error_message = "Request(s) whose `location` has no paired region: ${join(", ", [for name, dr_loc in local._instance_dr_locations : name if dr_loc == null])}. Every instance gets a second private endpoint in its paired region (and DR topologies put the DR instance there), so every location must be in default.json's dr_region_pairs (today: ${join(", ", [for p in local._dr_pair_list : "${p[0]} <-> ${p[1]}"])}). Either change that instance's location, or ask the platform team to add a pair. Non-DR requests in such a location get only their primary-region endpoint; DR requests fail in the redis module."
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

  # RediSearch + an explicitly requested clustering_policy other than
  # EnterpriseCluster: the module forces EnterpriseCluster, this makes it
  # visible.
  _requests_with_redisearch_clustering_conflict = [
    for name, payload in local._requested_instances : name
    if local._instance_wants_redisearch[name] && coalesce(try(payload.instance.clustering_policy, null), "EnterpriseCluster") != "EnterpriseCluster"
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

check "redisearch-requires-enterprise-cluster" {
  assert {
    condition     = length(local._requests_with_redisearch_clustering_conflict) == 0
    error_message = "Request(s) enabling RediSearch with an explicit clustering_policy other than EnterpriseCluster: ${join(", ", local._requests_with_redisearch_clustering_conflict)}. Azure requires EnterpriseCluster for RediSearch — the redis module forces it for this apply. Remove clustering_policy from the request, or set it to EnterpriseCluster."
  }
}

check "redisearch-requires-noeviction" {
  assert {
    condition     = length(local._requests_with_redisearch_eviction_conflict) == 0
    error_message = "Request(s) enabling RediSearch with an explicit eviction_policy other than NoEviction: ${join(", ", local._requests_with_redisearch_eviction_conflict)}. Azure requires NoEviction (and EnterpriseCluster clustering) for RediSearch — the redis module forces both for this apply. Remove eviction_policy from the request, or set it to NoEviction."
  }
}

############################################
# HA / clustering — early, per-request warnings.
#
# Advisory, same as the module checks above: the HARD enforcement is the
# redis module's lifecycle preconditions (plan fails). These only name
# the offending request.
############################################

locals {
  _requests_with_oss_on_standalone = [
    for name, cfg in local._redis_raw : name
    if cfg.deployment-topology == "STANDALONE" && cfg.clustering-policy == "OSSCluster"
  ]

  # Legacy NoCluster pin (pre-0.5.0 STANDALONE caches only): must be
  # STANDALONE and a SKU of 25 GB or less. Same list as the redis module's
  # local.defaults.legacy-nocluster-node-types.
  _legacy_nocluster_node_types = [
    "Balanced_B0", "Balanced_B1", "Balanced_B3", "Balanced_B5", "Balanced_B10", "Balanced_B20",
    "ComputeOptimized_X3", "ComputeOptimized_X5", "ComputeOptimized_X10", "ComputeOptimized_X20",
    "MemoryOptimized_M10", "MemoryOptimized_M20",
  ]
  _requests_with_invalid_legacy_nocluster = [
    for name, cfg in local._redis_raw : "${name} (${cfg.deployment-topology}, ${cfg.node-type})"
    if cfg.clustering-policy == "NoCluster" && (cfg.deployment-topology != "STANDALONE" || !contains(local._legacy_nocluster_node_types, cfg.node-type))
  ]

  _requests_with_ha_off_outside_standalone = [
    for name, cfg in local._redis_raw : name
    if cfg.deployment-topology != "STANDALONE" && cfg.high-availability-enabled == false
  ]

  # Persistence requires HA; only STANDALONE can be without it (unless the
  # request sets high_availability = true). DR-ActiveActive forces
  # persistence off itself, so it's never a conflict.
  _requests_with_persistence_without_ha = [
    for name, cfg in local._redis_raw : name
    if cfg.deployment-topology == "STANDALONE" && cfg.high-availability-enabled != true && cfg.persistence-mode != "DISABLED"
  ]
}

check "standalone-is-enterprise-cluster-only" {
  assert {
    condition     = length(local._requests_with_oss_on_standalone) == 0
    error_message = "STANDALONE request(s) asking for clustering_policy = OSSCluster: ${join(", ", local._requests_with_oss_on_standalone)}. STANDALONE caches are always EnterpriseCluster; OSSCluster is available for HA and DR topologies. Remove clustering_policy (or set EnterpriseCluster). Plan will fail in the redis module for these requests."
  }
}

check "legacy-nocluster-only-standalone-25gb" {
  assert {
    condition     = length(local._requests_with_invalid_legacy_nocluster) == 0
    error_message = "Request(s) with clustering_policy = NoCluster outside its legacy use: ${join(", ", local._requests_with_invalid_legacy_nocluster)}. NoCluster is only kept for STANDALONE caches created before template 0.5.0, on node_type of 25 GB or less (${join(", ", local._legacy_nocluster_node_types)}). New requests use EnterpriseCluster (or OSSCluster for HA/DR). Plan will fail in the redis module for these requests."
  }
}

check "ha-only-optional-for-standalone" {
  assert {
    condition     = length(local._requests_with_ha_off_outside_standalone) == 0
    error_message = "Request(s) with high_availability = false on an HA/DR topology: ${join(", ", local._requests_with_ha_off_outside_standalone)}. Only STANDALONE may run without HA. Remove high_availability from the request. Plan will fail in the redis module for these requests."
  }
}

check "persistence-requires-ha" {
  assert {
    condition     = length(local._requests_with_persistence_without_ha) == 0
    error_message = "STANDALONE request(s) with persistence enabled but high availability off: ${join(", ", local._requests_with_persistence_without_ha)}. Azure only supports RDB/AOF persistence with high availability. Set high_availability = true, or persistence.mode = DISABLED. Plan will fail in the redis module for these requests."
  }
}

############################################
# Environment rules — owned by this template, not the redis module.
############################################

locals {
  # Environments treated as production: STANDALONE (no HA, no DR) is
  # flagged for these.
  _production_like_envs = ["preprod", "prod"]

  # STANDALONE without HA (single node). STANDALONE with
  # high_availability = true is replicated, so it isn't flagged.
  _standalone_requests = [
    for name, topology in local._instance_topologies : name
    if topology == "STANDALONE" && try(local._requested_instances[name].instance.high_availability, false) != true
  ]

  # The module caps its full name at 57 characters (Azure's 60 minus
  # "-dr"); this template adds "-<env>", so the request's own name must
  # leave room for it. Hard-enforced by the module's name validation —
  # this check only names the offending request.
  _requests_with_name_too_long = [
    for name, payload in local._requested_instances : name
    if length("${payload.instance.name}-${var.env}") > 57
  ]
}

check "prod-should-not-be-standalone" {
  assert {
    condition     = !contains(local._production_like_envs, var.env) || length(local._standalone_requests) == 0
    error_message = "Environment '${var.env}' has STANDALONE request(s) without high availability: ${join(", ", local._standalone_requests)}. A single-node cache has no replica, no SLA and no DR. If this is intentional (e.g. a short-lived parity test), this check is advisory only and does not block the apply."
  }
}

check "instance-name-fits-with-environment" {
  assert {
    condition     = length(local._requests_with_name_too_long) == 0
    error_message = "Request(s) whose instance.name is too long once \"-${var.env}\" is added: ${join(", ", local._requests_with_name_too_long)}. <name>-<env> must be at most 57 characters (49 for the name itself, so it fits every environment including preprod). Plan will fail in the redis module for these requests."
  }
}
