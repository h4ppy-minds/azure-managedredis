############################################################################
# all-locals.tf — THE file to edit when you want to change an AZURE MANAGED
# REDIS INSTANCE default (topology, HA/clustering, persistence, auth,
# networking, deletion protection).
#
# Naming note: every local in this file uses hyphens, matching the
# kebab-case convention now used for every variable and output in this
# module (see variables.tf). Hyphens are legal in HCL identifiers; this
# extends that convention from the module's public interface (variables/
# outputs, which is what was specifically requested) into its internal
# locals too, for one consistent style across the whole file rather than
# a visible seam between "public" and "internal" names.
#
# Layout, top to bottom:
#   1. local.defaults      — every literal instance default value.
#   2. local.<name>        — the "effective" value of every variable that
#                            has a default: var.<name> if the caller set
#                            it, else local.defaults.<name>.
#   3. Derived locals       — values computed FROM the effective values
#                            above.
############################################################################

locals {

  ##########################################################################
  # 1. DEFAULTS — edit this map to change an instance default.
  ##########################################################################
  defaults = {
    deployment-topology = "STANDALONE"

    topology-profile = {
      STANDALONE = {
        high-availability-enabled = false
        clustering-policy         = "NoCluster"
        create-dr                 = false
        create-geo-replication    = false
      }
      HA = {
        high-availability-enabled = true
        clustering-policy         = "OSSCluster"
        create-dr                 = false
        create-geo-replication    = false
      }
      "DR-ActivePassive" = {
        high-availability-enabled = true
        clustering-policy         = "OSSCluster"
        create-dr                 = true
        create-geo-replication    = false
      }
      "DR-ActiveActive" = {
        high-availability-enabled = true
        clustering-policy         = "OSSCluster"
        create-dr                 = true
        create-geo-replication    = true
      }
    }

    # NOTE: there is deliberately no per-environment node-type default here
    # any more (v5.0.0). node-type is a REQUIRED variable — the caller
    # (typically an onboarding template with its own sizing policy) always
    # supplies it explicitly. See the CHANGELOG for the migration this
    # implies if you're upgrading from an earlier version.

    eviction-policy = "AllKeysLRU"

    # No modules unless the caller asks for them. See variables.tf
    # "Redis modules" — modules are create-time only.
    redis-modules     = []
    redis-module-args = {}

    authorization-mode = "AccessKey"

    persistence-mode          = "DISABLED"
    persistence-rdb-frequency = "12h"
    persistence-aof-frequency = "1s"

    deletion-protection-enabled = true

    create-timeout = "60m"
    tags           = {}
  }

  ##########################################################################
  # 2. EFFECTIVE VALUES — var override wins, else local.defaults.*.
  ##########################################################################

  environment         = var.environment
  deployment-topology = coalesce(var.deployment-topology, local.defaults.deployment-topology)

  # node-type has no default/coalesce — it's a required variable now, so
  # var.node-type is always already a real value. Referenced directly as
  # var.node-type in main.tf/variables.tf rather than duplicated as a
  # local with nothing left to do.

  high-availability-enabled = (
    var.high-availability-enabled != null
    ? var.high-availability-enabled
    : local.defaults.topology-profile[local.deployment-topology].high-availability-enabled
  )

  # --- Redis modules ---
  # Every accepted spelling (lower-cased) -> the canonical name Azure's API
  # expects. variables.tf validation guarantees every input is a key here.
  redis-module-aliases = {
    redisearch      = "RediSearch"
    search          = "RediSearch"
    redisjson       = "RedisJSON"
    json            = "RedisJSON"
    redisbloom      = "RedisBloom"
    bloom           = "RedisBloom"
    redistimeseries = "RedisTimeSeries"
    timeseries      = "RedisTimeSeries"
  }

  # Canonical names, de-duplicated and SORTED. Sorting matters: the module
  # block list is create-time only (a change forces replacement), so a
  # caller merely re-ordering the same modules must never produce a diff.
  redis-modules-input     = var.redis-modules != null ? var.redis-modules : local.defaults.redis-modules
  redis-module-args-input = var.redis-module-args != null ? var.redis-module-args : local.defaults.redis-module-args

  redis-modules = sort(distinct([
    for m in local.redis-modules-input : lookup(local.redis-module-aliases, lower(trimspace(m)), m)
  ]))

  # Keys normalised to canonical module names, values trimmed.
  redis-module-args = {
    for k, v in local.redis-module-args-input : lookup(local.redis-module-aliases, lower(trimspace(k)), k) => trimspace(v)
  }

  redisearch-enabled = contains(local.redis-modules, "RediSearch")

  # Topology/SKU value BEFORE the RediSearch override below — kept
  # separately only so the effective value stays one readable line.
  clustering-policy-requested = coalesce(
    var.clustering-policy,
    local.defaults.topology-profile[local.deployment-topology].clustering-policy
  )
  eviction-policy-requested = coalesce(var.eviction-policy, local.defaults.eviction-policy)

  # RediSearch requires EnterpriseCluster + NoEviction (Azure requirement).
  # Silently forced, same pattern as persistence for DR-ActiveActive — the
  # redisearch-forces-cluster-and-eviction-policy check warns when this
  # overrides an explicit caller value.
  clustering-policy = local.redisearch-enabled ? "EnterpriseCluster" : local.clustering-policy-requested
  eviction-policy   = local.redisearch-enabled ? "NoEviction" : local.eviction-policy-requested

  # Not tunable — see "Network exposure and transit encryption are
  # mandatory, not defaults" in variables.tf / README.md.
  client-protocol       = "Encrypted"
  public-network-access = "Disabled"

  authorization-mode                 = coalesce(var.authorization-mode, local.defaults.authorization-mode)
  access-keys-authentication-enabled = local.authorization-mode == "AccessKey"

  persistence-mode          = coalesce(var.persistence-mode, local.defaults.persistence-mode)
  persistence-rdb-frequency = coalesce(var.persistence-rdb-frequency, local.defaults.persistence-rdb-frequency)
  persistence-aof-frequency = coalesce(var.persistence-aof-frequency, local.defaults.persistence-aof-frequency)

  deletion-protection-enabled = (
    var.deletion-protection-enabled != null ? var.deletion-protection-enabled : local.defaults.deletion-protection-enabled
  )

  create-timeout = coalesce(var.create-timeout, local.defaults.create-timeout)
  tags           = var.tags != null ? var.tags : local.defaults.tags

  ##########################################################################
  # 3. DERIVED LOCALS
  ##########################################################################

  is-dev  = local.environment == "dev"
  is-prod = local.environment == "prod"

  create-dr              = local.defaults.topology-profile[local.deployment-topology].create-dr
  create-geo-replication = local.defaults.topology-profile[local.deployment-topology].create-geo-replication

  persistence-mode-effective = local.create-geo-replication ? "DISABLED" : local.persistence-mode

  # --- Networking resolution ---
  # Every instance gets a private endpoint — primary always, DR whenever
  # create-dr is true. There is no toggle to opt out of either. Subnet
  # info is therefore always required (enforced by the checks below and a
  # matching lifecycle.precondition in main.tf/network.tf).
  subnet-id = coalesce(var.subnet-id, try(data.azurerm_subnet.subnet[0].id, null))

  dr-subnet-id = var.dr-subnet-id != null ? var.dr-subnet-id : try(data.azurerm_subnet.dr-subnet[0].id, null)

  # Falls back to the primary's resource group only for backward
  # compatibility — see the variable's own description for why a
  # SEPARATE resource group per region is the production recommendation.
  dr-resource-group-name = coalesce(var.dr-resource-group-name, var.resource-group-name)

  # --- Precondition helpers (see main.tf / network.tf lifecycle blocks) ---
  valid-subnet-for-private-endpoint = local.subnet-id != null

  valid-dr-location-for-dr = !local.create-dr || var.dr-location != null

  # Whenever create-dr is true, DR must have a resolvable subnet — either
  # a direct dr-subnet-id, or a complete name-based lookup trio.
  valid-dr-subnet-inputs = (
    !local.create-dr ||
    var.dr-subnet-id != null ||
    (var.dr-subnet-name != null && var.dr-vnet-name != null && var.dr-vnet-resource-group-name != null)
  )

  # --- Redis module precondition helpers (see main.tf lifecycle blocks) ---
  # Each is the LIST of offending module names (empty = valid), so the
  # precondition error can say exactly which module is the problem.

  # Active geo-replication (DR-ActiveActive) supports only these modules.
  redis-modules-geo-replication-allowed = ["RediSearch", "RedisJSON"]
  redis-modules-invalid-for-geo-replication = local.create-geo-replication ? [
    for m in local.redis-modules : m if !contains(local.redis-modules-geo-replication-allowed, m)
  ] : []

  # Flash SKUs support only a subset of modules.
  redis-modules-allowed-for-sku = (
    startswith(var.node-type, "FlashOptimized_") ? ["RedisJSON"] :
    startswith(var.node-type, "EnterpriseFlash_") ? ["RediSearch", "RedisJSON"] :
    ["RediSearch", "RedisJSON", "RedisBloom", "RedisTimeSeries"]
  )
  redis-modules-invalid-for-sku = [
    for m in local.redis-modules : m if !contains(local.redis-modules-allowed-for-sku, m)
  ]

  # Args may only be given for a module that is actually enabled.
  redis-module-args-without-module = [
    for k in keys(local.redis-module-args) : k if !contains(local.redis-modules, k)
  ]
}
