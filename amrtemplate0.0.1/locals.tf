locals {

  # --- Layer 1: global technical defaults + per-environment infra ---
  # default.json is generated/maintained by the platform team in a
  # nested shape — persistence{}, environments.<env>.networking{},
  # environments.<env>.dr_networking{} — rather than flat keys matching
  # the redis module's variable names 1:1. `deletion_protection_enabled`
  # is a plain boolean, same pattern as the module itself. Every local
  # below that reads from local._defaults_raw names the exact nested
  # path it needs, field by field, instead of one generic top-level
  # merge() — see Layer 3's comment for why that distinction matters.
  _defaults_raw = jsondecode(file("${path.module}/config/onboarding-files-redis/default.json"))
  _env_infra    = local._defaults_raw.environments[var.env]

  # --- Layer 2: one onboarding request per file ---
  # Every *.json file in the folder except default.json is a self-service
  # request: { request_type, environment, requested_by, instance: {...} }.
  # Team PRs add or edit exactly one file — no shared file to
  # merge-conflict over.
  _all_instances = {
    for f in fileset("${path.module}/config/onboarding-files-redis", "*.json") :
    f => jsondecode(file("${path.module}/config/onboarding-files-redis/${f}"))
    if f != "default.json"
  }

  # Keyed by instance.name — NOT the physical Azure instance name (see
  # Layer 3, which appends "-${var.env}" to build that). This is the
  # stable Terraform for_each key, deliberately kept environment-agnostic,
  # so a request file's identity in state doesn't change if the
  # env-suffix logic below ever changes. Excludes anything not targeting
  # the current environment, and anything marked request_type = "delete".
  # Every request file's instance.name MUST be unique across ALL files
  # for this environment — two files sharing a name collide into a
  # single map entry and one request silently disappears. Unlike the
  # Valkey onboarding root (which only left a comment about this after
  # being bitten by it once), this template enforces it below with the
  # request_names_unique_per_environment check instead of relying on
  # someone noticing in review.
  _requested_instances = {
    for f, payload in local._all_instances :
    payload.instance.name => payload
    if payload.environment == var.env && payload.request_type != "delete"
  }

  # How many request files (targeting this environment, not deleted) map
  # to each instance.name — used only by the uniqueness check below.
  # Anything with count > 1 means two or more files collided into a
  # single map entry in _requested_instances.
  _instance_name_counts = {
    for f, payload in local._all_instances :
    payload.instance.name => f...
    if payload.environment == var.env && payload.request_type != "delete"
  }
}

check "request_names_unique_per_environment" {
  assert {
    condition = alltrue([
      for name, files in local._instance_name_counts : length(files) == 1
    ])
    error_message = "Two or more onboarding request files for environment '${var.env}' share the same instance.name — only one will actually be applied, the rest silently disappear. Colliding names: ${join(", ", [for name, files in local._instance_name_counts : "${name} (${join(", ", files)})" if length(files) > 1])}."
  }
}

locals {
  # --- Layer 3: defaults -> env infra -> instance overrides, flattened
  # into exactly the variable names the redis module expects.
  #
  # Every nested object here (persistence) is merged FIELD BY FIELD, not
  # with a single merge() of the whole sub-object — if an instance sets
  # only {"persistence": {"mode": "AOF"}}, a naive top-level merge() of
  # defaults.persistence and instance.persistence would still lose
  # whichever persistence sub-fields the instance's partial object
  # didn't restate the moment there's more than one persistence field in
  # play. try(instance.X.Y, defaults.X.Y) per leaf field avoids that
  # entirely — an instance can override just persistence.mode and still
  # inherit persistence.rdb_frequency / persistence.aof_frequency from
  # default.json.
  _redis_raw = {
    for name, payload in local._requested_instances :
    name => {
      # --- Identity ---
      # The physical Azure resource name always gets an environment
      # suffix — "my-cache" becomes "my-cache-dev" — so the same
      # request-file name can exist independently in every environment
      # without colliding, and the environment an instance belongs to is
      # legible from its name alone (Azure Portal, az cli output, an
      # incident channel) without going to look up tags.
      name                 = "${payload.instance.name}"
      environment          = var.env
      resource_group_name  = local._env_infra.resource_group_name

      # Primary location: instance-settable, falls back to the
      # environment's default location when a request doesn't specify
      # one. The module does not maintain its own region allow-list —
      # any Azure region is accepted as-is.
      location = try(payload.instance.location, local._env_infra.location)

      # --- Deployment topology ---
      # Unlike the Valkey onboarding root (which derives topology from
      # replica_count + cross_region_replica booleans), the redis
      # module already made deployment_topology the single settable
      # knob — so the request states it directly instead of this
      # template re-deriving it from other fields.
      deployment_topology = try(payload.instance.deployment_topology, local._defaults_raw.deployment_topology)

      # --- Sizing ---
      node_type = try(payload.instance.node_type, local._defaults_raw.node_type)

      # --- Networking — always environment infra, never
      # instance-settable (same rule as resource_group_name: a request
      # can ask for a topology, but never pick which VNet/subnet). ---
      subnet_name               = try(local._env_infra.networking.subnet_name, null)
      vnet_name                 = try(local._env_infra.networking.vnet_name, null)
      vnet_resource_group_name  = try(local._env_infra.networking.vnet_resource_group_name, null)

      # DR-region networking — only present for environments that have
      # a dr_networking block configured. Left null (not empty strings)
      # when absent so the module's own opt-in DR-private-endpoint logic
      # applies cleanly: DR instance still gets created, just without a
      # private endpoint, exactly like requesting DR in an environment
      # that has no DR-region VNet yet.
      dr_subnet_name              = try(local._env_infra.dr_networking.subnet_name, null)
      dr_vnet_name                = try(local._env_infra.dr_networking.vnet_name, null)
      dr_vnet_resource_group_name = try(local._env_infra.dr_networking.vnet_resource_group_name, null)

      # --- Auth / TLS ---
      # client_protocol / public_network_access are intentionally NOT
      # read from the request or default.json here — the module itself
      # hard-requires Encrypted / Disabled and rejects anything else via
      # variable validation, so there is no meaningful value this
      # template could pass except the one the module already defaults
      # to. authorization_mode, by contrast, IS a real request-settable
      # field (see schema) — the redis module doesn't hard-lock it the
      # way it hard-locks TLS/public access.
      authorization_mode = try(payload.instance.authorization_mode, local._defaults_raw.authorization_mode)

      # --- Persistence (field-by-field — see note above) ---
      persistence_mode          = try(payload.instance.persistence.mode, local._defaults_raw.persistence.mode)
      persistence_rdb_frequency = try(payload.instance.persistence.rdb_frequency, local._defaults_raw.persistence.rdb_frequency)
      persistence_aof_frequency = try(payload.instance.persistence.aof_frequency, local._defaults_raw.persistence.aof_frequency)

      eviction_policy = try(payload.instance.eviction_policy, local._defaults_raw.eviction_policy)

      # --- Deletion protection ---
      deletion_protection_enabled = try(payload.instance.deletion_protection_enabled, local._defaults_raw.deletion_protection_enabled)

      # --- Geo-replication group name override (DR-ActiveActive only) ---
      geo_replication_group_name = try(payload.instance.geo_replication_group_name, null)

      # --- Labels: application_id / lob arrive as instance-level fields
      # (NOT nested under instance.tags). application_id falls back to
      # default.json's default_application_id when a request doesn't
      # supply its own. lob has no default — a request either states
      # its own cost center or the tag is simply omitted. Both MUST end
      # up in tags regardless of source; that happens in Layer 4, once
      # topology/environment/managed_by are also known.
      _application_id = try(payload.instance.application_id, local._defaults_raw.default_application_id)
      _lob            = try(payload.instance.lob, null)
      # instance.tags remains supported as a passthrough for any other
      # ad-hoc tag a request wants to add (anything beyond
      # application_id/lob) — reserved keys (topology/environment/
      # managed_by, and now application_id/lob themselves, since those
      # have dedicated fields) are stripped in Layer 4 so there's exactly
      # one source of truth for each.
      _raw_tags = try(payload.instance.tags, {})

      # --- Raw DR signal, carried through for Layer 4 to derive
      # dr_location from via the region-pairing table below. Distinct
      # from deployment_topology itself: a request can ask for
      # DR-ActivePassive/DR-ActiveActive from a primary location that
      # simply has no configured DR pair yet, and that should fail
      # clearly (see the check below) rather than silently creating a
      # DR instance with no dr_location.
      _wants_dr = try(
        contains(["DR-ActivePassive", "DR-ActiveActive"], payload.instance.deployment_topology),
        contains(["DR-ActivePassive", "DR-ActiveActive"], local._defaults_raw.deployment_topology)
      )
    }
  }

  # --- Cross-region DR pairing ---
  # Cross-region replication is currently only supported between a fixed
  # set of region pairs — same constraint the Valkey onboarding root
  # documents, same reasoning for using a LIST of unordered pairs rather
  # than a symmetric map (one entry per pair, not two kept in sync by
  # hand). This local expands it into a bidirectional lookup map at plan
  # time.
  _dr_pair_list = try(local._defaults_raw.dr_region_pairs, [])
  _dr_region_pairs = merge([
    for pair in local._dr_pair_list : {
      (pair[0]) = pair[1]
      (pair[1]) = pair[0]
    }
  ]...)

  _topology_by_name = {
    for name, cfg in local._redis_raw :
    name => cfg.deployment_topology
  }

  # --- Layer 4: derive dr_location and tags — every value here needs
  # something only computable AFTER Layer 3's per-field merge.
  #
  # `topology`, `environment`, and `managed_by` are ALWAYS derived here
  # and never taken from the request file, even if a request sends them
  # under tags — that would be true duplication of a fact already stated
  # once (via deployment_topology / the request's own environment), with
  # nothing keeping the two copies in sync. Onboarding request files
  # should never set tags.topology, tags.environment, or tags.managed_by.
  redis = {
    for name, cfg in local._redis_raw :
    name => merge(cfg, {
      # Auto-picked from cfg.location (the PRIMARY region actually
      # chosen for this instance) via the supported-pairs table. try()
      # so an unsupported primary resolves to null (caught below by the
      # dr_requires_supported_region_pair check) instead of an opaque
      # "attribute not found" error.
      dr_location = cfg._wants_dr ? try(local._dr_region_pairs[cfg.location], null) : null

      tags = merge(
        { application_id = cfg._application_id },
        cfg._lob != null ? { lob = cfg._lob } : {},
        {
          for k, v in cfg._raw_tags : k => v
          if !contains(["application_id", "lob", "topology", "environment", "managed_by"], k)
        },
        {
          topology    = lower(cfg.deployment_topology)
          environment = var.env
          managed_by  = "terraform"
        }
      )
    })
  }
}

check "dr_requires_supported_region_pair" {
  assert {
    condition = alltrue([
      for name, cfg in local.redis : !cfg._wants_dr || cfg.dr_location != null
    ])
    error_message = "One or more DR requests picked a primary `location` with no supported DR secondary. Cross-region DR is currently only supported between the pairs listed in default.json's dr_region_pairs (today: ${join(", ", [for p in local._dr_pair_list : "${p[0]} <-> ${p[1]}"])}). Either change that instance's location to a supported primary, or ask the platform team to add a new pair to default.json.dr_region_pairs."
  }
}

