############################################################################
# all-locals.tf — THE file to edit when you want to change an AZURE MANAGED
# REDIS INSTANCE default (topology, sizing, HA/clustering, persistence,
# auth, networking, deletion protection).
#
# Layout of this file, top to bottom:
#   1. local.defaults      — every literal instance default value, in one
#                            map. Change a value here to change the
#                            module's default everywhere it's used.
#                            Nothing else in this repo needs to change.
#   2. local.<name>        — the "effective" value of every variable that
#                            has a default: var.<name> if the caller set
#                            it, else local.defaults.<name> (or, for the
#                            per-environment / per-topology values,
#                            local.defaults.environment_profile[...] /
#                            local.defaults.topology_profile[...]).
#                            main.tf, network.tf and data.tf read these,
#                            never var.* directly, for anything listed in
#                            local.defaults.
#   3. Derived locals       — values computed FROM the effective values
#                            above (subnet/DNS-zone resolution,
#                            precondition booleans for main.tf's
#                            lifecycle blocks). Not "defaults" themselves,
#                            just logic, but they live here too so the
#                            instance's behavior is readable from one
#                            file.
############################################################################

locals {

  ##########################################################################
  # 1. DEFAULTS — edit this map to change an instance default. Nothing else.
  ##########################################################################
  defaults = {
    # --- deployment topology ---
    # The single knob for HA/clustering/DR/geo-replication — there is no
    # separate high_availability_enabled-as-a-toggle or prod_mode variable
    # driving these independently. STANDALONE / HA / DR-ActivePassive /
    # DR-ActiveActive map 1:1 onto exactly one combination of
    # (high_availability_enabled, clustering_policy, DR instance?, live
    # geo-replication?) each, defined in topology_profile below.
    deployment_topology = "STANDALONE"

    topology_profile = {
      STANDALONE = {
        high_availability_enabled = false
        clustering_policy         = "NoCluster"
        create_dr                 = false
        create_geo_replication    = false
      }
      HA = {
        high_availability_enabled = true
        clustering_policy         = "OSSCluster"
        create_dr                 = false
        create_geo_replication    = false
      }
      "DR-ActivePassive" = {
        high_availability_enabled = true
        clustering_policy         = "OSSCluster"
        create_dr                 = true
        create_geo_replication    = false
      }
      "DR-ActiveActive" = {
        high_availability_enabled = true
        clustering_policy         = "OSSCluster"
        create_dr                 = true
        create_geo_replication    = true
      }
    }

    # --- per-environment sizing profile ---
    # environment still exists purely for naming and "how big should this
    # be by default" — it no longer drives HA/clustering/DR at all;
    # deployment_topology alone does that now (see topology_profile above).
    environment_profile = {
      dev  = { node_type = "Balanced_B0" }
      qa   = { node_type = "Balanced_B3" }
      uat  = { node_type = "Balanced_B3" }
      prod = { node_type = "Balanced_B3" }
    }

    # --- database config applied identically to primary & DR ---
    eviction_policy = "AllKeysLRU"

    # --- authorization ---
    # See the "Auth mode & TLS" section in variables.tf for why this
    # defaults to AccessKey rather than MicrosoftEntraID.
    authorization_mode = "AccessKey"

    # --- persistence ---
    # DISABLED by default, matching the underlying Azure API default.
    # Azure does not support persistence on a geo-replicated database —
    # see local.persistence_mode_effective below.
    persistence_mode          = "DISABLED"
    persistence_rdb_frequency = "12h"
    persistence_aof_frequency = "1s"

    # --- deletion protection ---
    # Unlike GCP's google_memorystore_instance, azurerm_managed_redis has
    # no deletion_protection_enabled argument of its own — see main.tf's
    # azurerm_management_lock resources, which are this module's
    # equivalent guard. Defaults to true (protected), matching the GCP
    # sibling module's "production by default" stance.
    deletion_protection_enabled = true

    # --- networking ---
    create_private_endpoint            = true
    create_private_dns_zone            = true
    private_dns_zone_vnet_link_enabled = true

    # --- misc ---
    create_timeout = "60m"
    tags           = {}
  }

  ##########################################################################
  # 2. EFFECTIVE VALUES — var override wins, else local.defaults.*.
  # main.tf, network.tf and data.tf read these, not var.*.
  ##########################################################################

  environment         = var.environment # required, no default — see variables.tf
  deployment_topology = coalesce(var.deployment_topology, local.defaults.deployment_topology)

  node_type = coalesce(
    var.node_type,
    local.defaults.environment_profile[local.environment].node_type
  )
  high_availability_enabled = (
    var.high_availability_enabled != null
    ? var.high_availability_enabled
    : local.defaults.topology_profile[local.deployment_topology].high_availability_enabled
  )
  clustering_policy = coalesce(
    var.clustering_policy,
    local.defaults.topology_profile[local.deployment_topology].clustering_policy
  )

  eviction_policy = coalesce(var.eviction_policy, local.defaults.eviction_policy)

  authorization_mode = coalesce(var.authorization_mode, local.defaults.authorization_mode)
  # The actual azurerm_managed_redis default_database argument this maps to.
  access_keys_authentication_enabled = local.authorization_mode == "AccessKey"

  persistence_mode          = coalesce(var.persistence_mode, local.defaults.persistence_mode)
  persistence_rdb_frequency = coalesce(var.persistence_rdb_frequency, local.defaults.persistence_rdb_frequency)
  persistence_aof_frequency = coalesce(var.persistence_aof_frequency, local.defaults.persistence_aof_frequency)

  deletion_protection_enabled = (
    var.deletion_protection_enabled != null ? var.deletion_protection_enabled : local.defaults.deletion_protection_enabled
  )

  create_private_endpoint = (
    var.create_private_endpoint != null ? var.create_private_endpoint : local.defaults.create_private_endpoint
  )
  create_private_dns_zone = (
    var.create_private_dns_zone != null ? var.create_private_dns_zone : local.defaults.create_private_dns_zone
  )
  private_dns_zone_vnet_link_enabled = (
    var.private_dns_zone_vnet_link_enabled != null
    ? var.private_dns_zone_vnet_link_enabled
    : local.defaults.private_dns_zone_vnet_link_enabled
  )

  create_timeout = coalesce(var.create_timeout, local.defaults.create_timeout)
  tags           = var.tags != null ? var.tags : local.defaults.tags

  # Not tunable — see the "Network exposure and transit encryption are
  # mandatory, not defaults" section in variables.tf / README.md. Exposed
  # as locals purely so main.tf reads local.* uniformly for every
  # default_database/instance attribute, defaulted or not.
  client_protocol       = "Encrypted"
  public_network_access = "Disabled"

  ##########################################################################
  # 3. DERIVED LOCALS — logic built from the effective values above.
  ##########################################################################

  is_dev  = local.environment == "dev"
  is_qa   = local.environment == "qa"
  is_uat  = local.environment == "uat"
  is_prod = local.environment == "prod"

  # DR and geo-replication are both purely a function of
  # deployment_topology now — not of environment, and not of two separate
  # booleans that could disagree with each other.
  create_dr              = local.defaults.topology_profile[local.deployment_topology].create_dr
  create_geo_replication = local.defaults.topology_profile[local.deployment_topology].create_geo_replication

  # Azure rejects persistence on a geo-replicated database — back off
  # automatically rather than failing the apply. The
  # persistence_disabled_for_active_active check in variables.tf warns
  # when this silently changes what was requested.
  persistence_mode_effective = local.create_geo_replication ? "DISABLED" : local.persistence_mode

  # --- Networking resolution (primary) ---
  # Prefer a directly supplied subnet_id/vnet_id; fall back to the
  # name-based lookup data sources (data.tf) only when one wasn't given.
  subnet_id = coalesce(var.subnet_id, try(data.azurerm_subnet.subnet[0].id, null))
  vnet_id   = coalesce(var.vnet_id, try(data.azurerm_virtual_network.vnet[0].id, null))

  private_dns_zone_ids = local.create_private_dns_zone ? (
    length(azurerm_private_dns_zone.private_dns) > 0 ? [azurerm_private_dns_zone.private_dns[0].id] : []
  ) : coalesce(var.private_dns_zone_ids, [])

  # DR private endpoint is opt-in: only created when there's a DR instance,
  # private endpoints are enabled at all, and the caller gave us a subnet in
  # the DR region — either directly (dr_subnet_id) or via name-based lookup
  # (dr_subnet_name + dr_vnet_name + dr_vnet_resource_group_name).
  #
  # NOTE: this is keyed off the RAW var.* inputs, not local.dr_subnet_id.
  # local.dr_subnet_id (below) depends on data.azurerm_subnet.dr_subnet,
  # and that data source's own `count` (data.tf) depends on
  # create_dr_private_endpoint — so if this local read local.dr_subnet_id
  # instead, you'd get local.dr_subnet_id -> data source -> this local ->
  # local.dr_subnet_id, a dependency cycle Terraform will refuse to plan.
  # Keeping this one-directional (raw inputs -> this local -> data source
  # count -> local.dr_subnet_id -> everything downstream) avoids that.
  create_dr_private_endpoint = (
    local.create_dr && local.create_private_endpoint &&
    (var.dr_subnet_id != null || var.dr_subnet_name != null)
  )

  # --- Networking resolution (DR) ---
  dr_subnet_id = var.dr_subnet_id != null ? var.dr_subnet_id : try(data.azurerm_subnet.dr_subnet[0].id, null)
  dr_vnet_id   = var.dr_vnet_id != null ? var.dr_vnet_id : try(data.azurerm_virtual_network.dr_vnet[0].id, null)

  # --- Precondition helpers (see main.tf / network.tf lifecycle blocks) ---
  valid_subnet_for_private_endpoint = !local.create_private_endpoint || local.subnet_id != null
  valid_dr_location_for_dr          = !local.create_dr || var.dr_location != null
  valid_vnet_id_for_dns_link = (
    !(local.create_private_endpoint && local.create_private_dns_zone && local.private_dns_zone_vnet_link_enabled) ||
    local.vnet_id != null
  )

  # Valid whenever: a direct dr_subnet_id was given, OR no DR subnet
  # lookup was attempted at all (DR private endpoint is opt-in — that's
  # fine), OR a name-based lookup was attempted with all three required
  # pieces. Catches the partial-input case: dr_subnet_name set but
  # dr_vnet_name/dr_vnet_resource_group_name forgotten.
  valid_dr_subnet_inputs = (
    var.dr_subnet_id != null ||
    var.dr_subnet_name == null ||
    (var.dr_vnet_name != null && var.dr_vnet_resource_group_name != null)
  )

  # Only meaningful once a DR private endpoint actually exists — mirrors
  # valid_vnet_id_for_dns_link, scoped to the DR region's VNet link.
  valid_dr_vnet_id_for_dns_link = (
    !(local.create_dr_private_endpoint && local.create_private_dns_zone && local.private_dns_zone_vnet_link_enabled) ||
    local.dr_vnet_id != null
  )
}
