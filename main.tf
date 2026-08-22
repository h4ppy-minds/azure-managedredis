############################################
# Primary and DR Azure Managed Redis instance(s).
#
# Primary and DR are both azurerm_managed_redis, but not expressed with a
# shared for_each/count over one shape: they aren't symmetric — different
# location, and (in DR-ActiveActive mode) the geo-replication link is a
# separate resource (geo-replication.tf) that depends on both existing
# first. Two explicit resource blocks keeps that dependency simple.
#
# This module has no submodules — everything a consumer needs to read is
# in this one directory. The two blocks below necessarily repeat most of
# their arguments; that's the tradeoff for a flat, single-directory
# module instead of a shared internal one.
#
# Topology: local.deployment_topology (all-locals.tf) is the single
# source of truth for HA, clustering, whether DR exists at all
# (local.create_dr), and whether it's live-replicated
# (local.create_geo_replication). None of these is a separate yes/no
# variable that could disagree with the others.
############################################

resource "azurerm_managed_redis" "primary" {
  name                       = "${var.name}-${local.environment}"
  location                   = var.location
  resource_group_name        = var.resource_group_name
  high_availability_enabled  = local.high_availability_enabled
  sku_name                   = local.node_type # this module's public input is named node_type — see variables.tf
  public_network_access      = local.public_network_access
  tags                       = local.tags

  default_database {
    clustering_policy                             = local.clustering_policy
    client_protocol                                = local.client_protocol
    eviction_policy                                = local.eviction_policy
    access_keys_authentication_enabled             = local.access_keys_authentication_enabled
    geo_replication_group_name                     = local.create_geo_replication ? var.geo_replication_group_name : null
    persistence_redis_database_backup_frequency    = local.persistence_mode_effective == "RDB" ? local.persistence_rdb_frequency : null
    persistence_append_only_file_backup_frequency  = local.persistence_mode_effective == "AOF" ? local.persistence_aof_frequency : null
  }

  timeouts {
    create = local.create_timeout
  }

  lifecycle {
    precondition {
      condition     = local.valid_subnet_for_private_endpoint
      error_message = "create_private_endpoint resolved to true but no subnet could be resolved. Set subnet_id, or all of subnet_name/vnet_name/vnet_resource_group_name."
    }
  }
}

# DR instance: only when deployment_topology is one of the DR-* values.
#
# DR-ActiveActive: linked to the primary via
# azurerm_managed_redis_geo_replication (geo-replication.tf), giving live
# bidirectional replication.
# DR-ActivePassive: provisioned as a standalone standby. Azure Managed
# Redis has no native "passive replica" concept, so keeping this in sync
# is a customer-managed process today — see README "Known limitations."
resource "azurerm_managed_redis" "dr" {
  count = local.create_dr ? 1 : 0

  name                       = "${var.name}-${local.environment}-dr"
  location                   = coalesce(var.dr_location, var.location)
  resource_group_name        = var.resource_group_name
  high_availability_enabled  = local.high_availability_enabled
  sku_name                   = local.node_type # must match the primary's node_type for geo-replication
  public_network_access      = local.public_network_access
  tags                       = local.tags

  default_database {
    clustering_policy                             = local.clustering_policy
    client_protocol                                = local.client_protocol
    eviction_policy                                = local.eviction_policy
    access_keys_authentication_enabled             = local.access_keys_authentication_enabled
    geo_replication_group_name                     = local.create_geo_replication ? var.geo_replication_group_name : null
    persistence_redis_database_backup_frequency    = local.persistence_mode_effective == "RDB" ? local.persistence_rdb_frequency : null
    persistence_append_only_file_backup_frequency  = local.persistence_mode_effective == "AOF" ? local.persistence_aof_frequency : null
  }

  timeouts {
    create = local.create_timeout
  }

  lifecycle {
    precondition {
      condition     = local.valid_dr_location_for_dr
      error_message = "deployment_topology = '${local.deployment_topology}' requires dr_location to be set."
    }
  }
}

############################################
# Deletion protection
#
# azurerm_managed_redis has no deletion_protection_enabled argument of its
# own — this is this module's equivalent guard. See the
# deletion_protection_enabled variable for details on what this does and
# doesn't cover.
############################################

resource "azurerm_management_lock" "primary" {
  count = local.deletion_protection_enabled ? 1 : 0

  name       = "lock-${var.name}-${local.environment}"
  scope      = azurerm_managed_redis.primary.id
  lock_level = "CanNotDelete"
  notes      = "Managed by Terraform (redis module) — deletion_protection_enabled = true. Remove via deletion_protection_enabled = false, not by deleting this lock directly, so state and reality stay in sync."
}

resource "azurerm_management_lock" "dr" {
  count = local.create_dr && local.deletion_protection_enabled ? 1 : 0

  name       = "lock-${var.name}-${local.environment}-dr"
  scope      = azurerm_managed_redis.dr[0].id
  lock_level = "CanNotDelete"
  notes      = "Managed by Terraform (redis module) — deletion_protection_enabled = true. Remove via deletion_protection_enabled = false, not by deleting this lock directly, so state and reality stay in sync."
}
