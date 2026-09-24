############################################
# Primary and DR Azure Managed Redis instance(s).
#
# local.deployment-topology (all-locals.tf) is the single source of truth
# for HA, clustering, whether DR exists at all (local.create-dr), and
# whether it's live-replicated (local.create-geo-replication).
#
# TAGS: both resources below use lifecycle { ignore_changes = [tags] }.
# Tags are set on first create only — Terraform will never modify them on
# any later apply, even if var.tags changes. This is deliberate: tagging
# automation outside Terraform (e.g. Infoblox, a governance/policy tool)
# is never reverted by a subsequent apply/patch. The real tradeoff: if you
# genuinely need to change an EXISTING instance's tags going forward, this
# module will not do it for you — that has to happen out-of-band (Azure
# Portal/CLI) or by temporarily removing ignore_changes for one apply.
############################################

resource "azurerm_managed_redis" "primary" {
  name                      = "${var.name}-${local.environment}"
  location                  = var.location
  resource_group_name       = var.resource-group-name
  high_availability_enabled = local.high-availability-enabled
  sku_name                  = var.node-type
  public_network_access     = local.public-network-access
  tags                      = local.tags

  default_database {
    clustering_policy                             = local.clustering-policy
    client_protocol                               = local.client-protocol
    eviction_policy                               = local.eviction-policy
    access_keys_authentication_enabled            = local.access-keys-authentication-enabled
    geo_replication_group_name                    = local.create-geo-replication ? var.geo-replication-group-name : null
    persistence_redis_database_backup_frequency   = local.persistence-mode-effective == "RDB" ? local.persistence-rdb-frequency : null
    persistence_append_only_file_backup_frequency = local.persistence-mode-effective == "AOF" ? local.persistence-aof-frequency : null

    # Redis modules — create-time only (changing this list forces
    # replacement). Iterator renamed to "m": inside a dynamic "module"
    # block the default iterator name would be `module`, and
    # `module.value` would be read as a reference to a Terraform module
    # call, not this block's element.
    dynamic "module" {
      for_each = local.redis-modules
      iterator = m
      content {
        name = m.value
        args = lookup(local.redis-module-args, m.value, null)
      }
    }
  }

  timeouts {
    create = local.create-timeout
  }

  lifecycle {
    ignore_changes = [tags]

    precondition {
      condition     = local.valid-subnet-for-private-endpoint
      error_message = "No subnet could be resolved for the (always-created) private endpoint. Set subnet-id, or all of subnet-name/vnet-name/vnet-resource-group-name."
    }

    # --- Redis modules: combinations Azure rejects at create time. ---
    # Checked on the primary only — the DR instance always gets the exact
    # same module list, so one failure point is enough.
    precondition {
      condition     = length(local.redis-modules-invalid-for-geo-replication) == 0
      error_message = "deployment-topology = DR-ActiveActive (active geo-replication) supports only the RediSearch and RedisJSON modules. Remove: ${join(", ", local.redis-modules-invalid-for-geo-replication)} — or choose a different deployment-topology."
    }
    precondition {
      condition     = length(local.redis-modules-invalid-for-sku) == 0
      error_message = "node-type '${var.node-type}' does not support the module(s): ${join(", ", local.redis-modules-invalid-for-sku)}. Modules allowed on this SKU: ${join(", ", local.redis-modules-allowed-for-sku)}."
    }
    precondition {
      condition     = length(local.redis-module-args-without-module) == 0
      error_message = "redis-module-args sets args for module(s) not listed in redis-modules: ${join(", ", local.redis-module-args-without-module)}. Add them to redis-modules, or remove their args."
    }
  }
}

# DR instance: only when deployment-topology is one of the DR-* values.
resource "azurerm_managed_redis" "dr" {
  count = local.create-dr ? 1 : 0

  name                      = "${var.name}-${local.environment}-dr"
  location                  = coalesce(var.dr-location, var.location)
  resource_group_name       = local.dr-resource-group-name
  high_availability_enabled = local.high-availability-enabled
  sku_name                  = var.node-type # must match the primary's node-type for geo-replication
  public_network_access     = local.public-network-access
  tags                      = local.tags

  default_database {
    clustering_policy                             = local.clustering-policy
    client_protocol                               = local.client-protocol
    eviction_policy                               = local.eviction-policy
    access_keys_authentication_enabled            = local.access-keys-authentication-enabled
    geo_replication_group_name                    = local.create-geo-replication ? var.geo-replication-group-name : null
    persistence_redis_database_backup_frequency   = local.persistence-mode-effective == "RDB" ? local.persistence-rdb-frequency : null
    persistence_append_only_file_backup_frequency = local.persistence-mode-effective == "AOF" ? local.persistence-aof-frequency : null

    # Redis modules — create-time only (changing this list forces
    # replacement). Iterator renamed to "m": inside a dynamic "module"
    # block the default iterator name would be `module`, and
    # `module.value` would be read as a reference to a Terraform module
    # call, not this block's element.
    dynamic "module" {
      for_each = local.redis-modules
      iterator = m
      content {
        name = m.value
        args = lookup(local.redis-module-args, m.value, null)
      }
    }
  }

  timeouts {
    create = local.create-timeout
  }

  lifecycle {
    ignore_changes = [tags]

    precondition {
      condition     = local.valid-dr-location-for-dr
      error_message = "deployment-topology = '${local.deployment-topology}' requires dr-location to be set."
    }
    precondition {
      condition     = local.valid-dr-subnet-inputs
      error_message = "deployment-topology = '${local.deployment-topology}' creates a DR instance, which always gets a private endpoint. Set dr-subnet-id, or all of dr-subnet-name/dr-vnet-name/dr-vnet-resource-group-name."
    }
  }
}

############################################
# Deletion protection
############################################

resource "azurerm_management_lock" "primary" {
  count = local.deletion-protection-enabled ? 1 : 0

  name       = "lock-${var.name}-${local.environment}"
  scope      = azurerm_managed_redis.primary.id
  lock_level = "CanNotDelete"
  notes      = "Managed by Terraform (redis module) — deletion-protection-enabled = true. Remove via deletion-protection-enabled = false, not by deleting this lock directly, so state and reality stay in sync."
}

resource "azurerm_management_lock" "dr" {
  count = local.create-dr && local.deletion-protection-enabled ? 1 : 0

  name       = "lock-${var.name}-${local.environment}-dr"
  scope      = azurerm_managed_redis.dr[0].id
  lock_level = "CanNotDelete"
  notes      = "Managed by Terraform (redis module) — deletion-protection-enabled = true. Remove via deletion-protection-enabled = false, not by deleting this lock directly, so state and reality stay in sync."
}
