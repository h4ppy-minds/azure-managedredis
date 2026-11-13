############################################
# Primary and DR Azure Managed Redis instance(s).
#
# local.deployment-topology (all-locals.tf) is the single source of truth
# for HA, whether DR exists at all (local.create-dr), and whether it's
# live-replicated (local.create-geo-replication). It also limits the
# clustering policy (local.clustering-policies-allowed): STANDALONE is
# EnterpriseCluster only; HA/DR allow EnterpriseCluster (default) or OSS.
#
# CLUSTERING POLICY GUARD: both resources below ignore changes to
# default_database[0].clustering_policy and carry a postcondition that
# the instance's ACTUAL policy equals the requested one. Why: the azurerm
# provider (4.x) applies a clustering_policy change by DELETING and
# re-creating the database — all data lost — while `terraform plan` shows
# only "~ update in-place". With ignore_changes the planned value stays
# the real one, so the postcondition fails the PLAN, naming the instance,
# instead of silently wiping it at apply. A new instance (or one
# replaced with `-replace=`) is built from config, so it always passes.
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
  name                       = var.name
  location                   = var.location
  resource_group_name        = var.resource-group-name
  high_availability_enabled  = local.high-availability-enabled
  sku_name                   = var.node-type
  public_network_access      = local.public-network-access
  tags                       = local.tags

  default_database {
    clustering_policy                             = local.clustering-policy
    client_protocol                                = local.client-protocol
    eviction_policy                                = local.eviction-policy
    access_keys_authentication_enabled             = local.access-keys-authentication-enabled
    geo_replication_group_name                     = local.create-geo-replication ? var.geo-replication-group-name : null
    persistence_redis_database_backup_frequency    = local.persistence-mode-effective == "RDB" ? local.persistence-rdb-frequency : null
    persistence_append_only_file_backup_frequency  = local.persistence-mode-effective == "AOF" ? local.persistence-aof-frequency : null

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
    ignore_changes = [tags, default_database[0].clustering_policy]

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

    # --- Platform policy for HA / clustering per topology (see
    # local.defaults.topology-profile), plus Azure's HA requirements.
    # Checked on the primary only — the DR instance always gets the same
    # values. ---
    precondition {
      condition     = local.valid-clustering-for-topology
      error_message = "clustering-policy = '${local.clustering-policy-requested}' is not offered for deployment-topology = '${local.deployment-topology}'. Allowed: ${join(", ", local.clustering-policies-allowed)} (default ${local.clustering-policies-allowed[0]}). STANDALONE caches are EnterpriseCluster (NoCluster only as an explicit legacy pin for STANDALONE caches created before v0.5.0); OSSCluster is available for HA and DR topologies."
    }
    precondition {
      condition     = local.valid-legacy-nocluster-for-sku
      error_message = "Legacy clustering-policy = NoCluster is only possible on in-memory SKUs of 25 GB or less, but node-type = '${var.node-type}'. Allowed: ${join(", ", local.defaults.legacy-nocluster-node-types)}."
    }
    precondition {
      condition     = local.valid-ha-for-topology
      error_message = "high-availability-enabled = false is only allowed for deployment-topology = STANDALONE. '${local.deployment-topology}' always runs with high availability${local.create-geo-replication ? " (Azure also requires HA for active geo-replication)" : ""}. Remove the override."
    }
    precondition {
      condition     = local.valid-persistence-for-ha
      error_message = "persistence-mode = '${local.persistence-mode-effective}' requires high availability, but this instance has HA off (deployment-topology = '${local.deployment-topology}'). Azure only supports persistence on HA instances. For STANDALONE set high-availability-enabled = true (request field high_availability), or use persistence-mode = DISABLED."
    }
    # See "CLUSTERING POLICY GUARD" at the top of this file.
    postcondition {
      condition     = self.default_database[0].clustering_policy == local.clustering-policy
      error_message = "Clustering policy change blocked for ${self.name}: it is ${self.default_database[0].clustering_policy} today but ${local.clustering-policy} was requested. The azurerm provider applies this by deleting and re-creating the database (ALL DATA LOST) even though the plan would only show an in-place update, so this module refuses it. Either (a) keep the cache as it is: set clustering-policy (request field clustering_policy) to ${self.default_database[0].clustering_policy}; or (b) migrate deliberately: export/back up the data, set deletion-protection-enabled = false, keep the new value, and run `terraform apply -replace=<this resource address>`, then re-import data. Remember OSSCluster needs a cluster-aware client and EnterpriseCluster a standard one."
    }
  }
}

# DR instance: only when deployment-topology is one of the DR-* values.
resource "azurerm_managed_redis" "dr" {
  count = local.create-dr ? 1 : 0

  name                       = "${var.name}-dr"
  location                   = coalesce(var.dr-location, var.location)
  resource_group_name        = local.dr-resource-group-name
  high_availability_enabled  = local.high-availability-enabled
  sku_name                   = var.node-type # must match the primary's node-type for geo-replication
  public_network_access      = local.public-network-access
  tags                       = local.tags

  default_database {
    clustering_policy                             = local.clustering-policy
    client_protocol                                = local.client-protocol
    eviction_policy                                = local.eviction-policy
    access_keys_authentication_enabled             = local.access-keys-authentication-enabled
    geo_replication_group_name                     = local.create-geo-replication ? var.geo-replication-group-name : null
    persistence_redis_database_backup_frequency    = local.persistence-mode-effective == "RDB" ? local.persistence-rdb-frequency : null
    persistence_append_only_file_backup_frequency  = local.persistence-mode-effective == "AOF" ? local.persistence-aof-frequency : null

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
    ignore_changes = [tags, default_database[0].clustering_policy]

    precondition {
      condition     = local.valid-dr-location-for-dr
      error_message = "deployment-topology = '${local.deployment-topology}' requires dr-location to be set."
    }
    precondition {
      condition     = local.valid-dr-subnet-inputs
      error_message = "deployment-topology = '${local.deployment-topology}' creates a DR instance, which always gets a private endpoint. Set dr-subnet-id, or all of dr-subnet-name/dr-vnet-name/dr-vnet-resource-group-name."
    }
    # See "CLUSTERING POLICY GUARD" at the top of this file.
    postcondition {
      condition     = self.default_database[0].clustering_policy == local.clustering-policy
      error_message = "Clustering policy change blocked for ${self.name}: it is ${self.default_database[0].clustering_policy} today but ${local.clustering-policy} was requested. The azurerm provider applies this by deleting and re-creating the database (ALL DATA LOST) even though the plan would only show an in-place update, so this module refuses it. Either (a) keep the cache as it is: set clustering-policy (request field clustering_policy) to ${self.default_database[0].clustering_policy}; or (b) migrate deliberately: export/back up the data, set deletion-protection-enabled = false, keep the new value, and run `terraform apply -replace=<this resource address>`, then re-import data. Remember OSSCluster needs a cluster-aware client and EnterpriseCluster a standard one."
    }
  }
}

############################################
# Deletion protection
############################################

resource "azurerm_management_lock" "primary" {
  count = local.deletion-protection-enabled ? 1 : 0

  name       = "lock-${var.name}"
  scope      = azurerm_managed_redis.primary.id
  lock_level = "CanNotDelete"
  notes      = "Managed by Terraform (redis module) — deletion-protection-enabled = true. Remove via deletion-protection-enabled = false, not by deleting this lock directly, so state and reality stay in sync."
}

resource "azurerm_management_lock" "dr" {
  count = local.create-dr && local.deletion-protection-enabled ? 1 : 0

  name       = "lock-${var.name}-dr"
  scope      = azurerm_managed_redis.dr[0].id
  lock_level = "CanNotDelete"
  notes      = "Managed by Terraform (redis module) — deletion-protection-enabled = true. Remove via deletion-protection-enabled = false, not by deleting this lock directly, so state and reality stay in sync."
}
