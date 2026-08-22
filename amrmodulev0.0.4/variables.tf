############################################
# Core Identity
############################################

# --- REQUIRED ---
variable "name" {
  description = "Base name of the AMR instance to be created. Environment is appended as a suffix (e.g. name = \"cfes-amr\", environment = \"prod\" -> \"cfes-amr-prod\"). Required — no default, to prevent accidentally deploying under a placeholder name."
  type        = string
}

# --- REQUIRED ---
variable "location" {
  description = "Azure region for the primary instance (e.g. eastus2). Required — no module-wide default makes sense for where a customer's data lives."
  type        = string
}

# --- REQUIRED ---
variable "resource_group_name" {
  description = "Resource group where every resource in this module is created."
  type        = string
}

# --- OPTIONAL ---
variable "tags" {
  description = "Tags applied to every resource this module creates (instances, private endpoint(s), DNS zone, DNS link, and the deletion-protection lock if enabled). Default (see local.defaults.tags in all-locals.tf): {}."
  type        = map(string)
  default     = null
  nullable    = true
}

# --- OPTIONAL ---
variable "environment" {
  description = "Deployment environment: dev, qa, uat, or prod. Used for naming and for the per-environment node_type default in local.defaults.environment_profile (all-locals.tf). Does NOT drive HA/clustering/DR any more — deployment_topology alone does that (see below). Required if you rely on the per-environment node_type default; always required for naming."
  type        = string

  validation {
    condition     = contains(["dev", "qa", "uat", "prod"], var.environment)
    error_message = "environment must be one of: dev, qa, uat, prod."
  }
}

############################################
# Deployment Topology
############################################

# --- OPTIONAL ---
variable "deployment_topology" {
  description = <<-EOT
    The single knob for topology — this is the only input; there is no
    separate high_availability_enabled-as-a-toggle or prod_mode variable
    driving HA/clustering/DR independently (both existed in this module's
    prior version and could disagree with each other). Default (when left
    null): see local.defaults.deployment_topology in all-locals.tf.
      STANDALONE: single instance, no HA, no DR. high_availability_enabled
        = false, clustering_policy = NoCluster.
      HA: single-region instance with HA/zone redundancy enabled, no DR.
        high_availability_enabled = true, clustering_policy = OSSCluster.
      DR-ActivePassive: adds a DR instance in dr_location. Azure Managed
        Redis has no native "passive replica" concept, so this DR instance
        is a standalone standby you keep in sync yourself (RDB/AOF export-
        import, or a secondary write path). See README "Known
        limitations."
      DR-ActiveActive: adds a DR instance in dr_location, linked to the
        primary via azurerm_managed_redis_geo_replication — live,
        bidirectional replication. Azure does not support persistence on a
        geo-replicated database, so persistence_mode is silently forced to
        DISABLED in this mode (see the persistence_disabled_for_active_active
        check below).
    Requires dr_location whenever it resolves to one of the DR-* values
    (enforced by the dr_requires_location check below).
  EOT
  type        = string
  default     = null
  nullable    = true

  validation {
    condition = var.deployment_topology == null ? true : contains(
      ["STANDALONE", "HA", "DR-ActivePassive", "DR-ActiveActive"],
      var.deployment_topology
    )
    error_message = "deployment_topology must be one of: STANDALONE, HA, DR-ActivePassive, DR-ActiveActive."
  }
}

# --- OPTIONAL ---
variable "dr_location" {
  description = "Azure region for the DR instance (e.g. centralus). Required whenever deployment_topology resolves to DR-ActivePassive or DR-ActiveActive (enforced by the dr_requires_location check below) — no centralized default, since null is the meaningful 'no DR region chosen' state, not a value to retune."
  type        = string
  default     = null
  nullable    = true
}

# --- OPTIONAL ---
variable "geo_replication_group_name" {
  description = "Optional name override for the geo-replication group used by DR-ActiveActive. If null, Azure generates one. Only used when deployment_topology = DR-ActiveActive."
  type        = string
  default     = null
  nullable    = true
}

############################################
# Networking
#
# Loosely coupled on purpose: pass an existing subnet_id directly
# (preferred), or provide subnet_name/vnet_name/vnet_resource_group_name
# and the module will look it up for you. Same bring-your-own-or-create
# pattern for the private DNS zone.
############################################

# --- OPTIONAL ---
variable "create_private_endpoint" {
  description = "Whether this module creates a Private Endpoint for the primary (and optionally DR) Redis instance. Set to false if private connectivity is managed outside this module. Default (see all-locals.tf): true."
  type        = bool
  default     = null
  nullable    = true
}

# --- OPTIONAL ---
variable "subnet_id" {
  description = "Resource ID of an existing subnet for the primary private endpoint. Takes precedence over subnet_name/vnet_name/vnet_resource_group_name. Required (by one route or the other) whenever create_private_endpoint resolves to true — enforced by the private_endpoint_requires_subnet check below."
  type        = string
  default     = null
  nullable    = true
}

# --- OPTIONAL ---
variable "subnet_name" {
  description = "Name of the subnet to look up when subnet_id is not supplied. Used together with vnet_name and vnet_resource_group_name."
  type        = string
  default     = null
  nullable    = true
}

# --- OPTIONAL ---
variable "vnet_name" {
  description = "Name of the virtual network containing subnet_name."
  type        = string
  default     = null
  nullable    = true
}

# --- OPTIONAL ---
variable "vnet_resource_group_name" {
  description = "Resource group containing vnet_name."
  type        = string
  default     = null
  nullable    = true
}

# --- OPTIONAL ---
variable "vnet_id" {
  description = "Resource ID of the VNet to link a newly created private DNS zone to. Required when create_private_dns_zone and private_dns_zone_vnet_link_enabled both resolve to true — enforced by the private_dns_zone_link_requires_vnet_id check below."
  type        = string
  default     = null
  nullable    = true
}

# --- OPTIONAL ---
variable "dr_subnet_id" {
  description = "Resource ID of the subnet in the DR region for the DR Redis private endpoint. If null, no private endpoint is created for the DR instance — this is an opt-in feature, not a required one, since a DR-region VNet may not exist yet when DR is first stood up."
  type        = string
  default     = null
  nullable    = true
}

# --- OPTIONAL ---
variable "dr_subnet_name" {
  description = "Name of the DR-region subnet to look up when dr_subnet_id is not supplied. Used together with dr_vnet_name and dr_vnet_resource_group_name. Like dr_subnet_id, this is opt-in — omit all three to skip the DR private endpoint entirely."
  type        = string
  default     = null
  nullable    = true
}

# --- OPTIONAL ---
variable "dr_vnet_name" {
  description = "Name of the DR-region virtual network containing dr_subnet_name."
  type        = string
  default     = null
  nullable    = true
}

# --- OPTIONAL ---
variable "dr_vnet_resource_group_name" {
  description = "Resource group containing dr_vnet_name."
  type        = string
  default     = null
  nullable    = true
}

# --- OPTIONAL ---
variable "dr_vnet_id" {
  description = "Resource ID of the DR-region VNet to link the private DNS zone to (a second VNet link, alongside the primary's vnet_id) — required for DR-region clients to resolve the Redis hostname through the same zone. If null and dr_vnet_name/dr_vnet_resource_group_name are supplied, resolved automatically."
  type        = string
  default     = null
  nullable    = true
}

# --- OPTIONAL ---
variable "create_private_dns_zone" {
  description = "Whether to create a new privatelink.redis.azure.net private DNS zone. Set to false and pass private_dns_zone_ids to bring your own (e.g. a shared hub-and-spoke zone managed elsewhere). Default (see all-locals.tf): true."
  type        = bool
  default     = null
  nullable    = true
}

# --- OPTIONAL ---
variable "private_dns_zone_ids" {
  description = "Existing private DNS zone IDs to associate with the private endpoint(s). Only used when create_private_dns_zone = false."
  type        = list(string)
  default     = null
  nullable    = true
}

# --- OPTIONAL ---
variable "private_dns_zone_vnet_link_enabled" {
  description = "When creating a new private DNS zone, link it to vnet_id so records resolve inside that VNet. Default (see all-locals.tf): true."
  type        = bool
  default     = null
  nullable    = true
}

############################################
# Sizing / HA / Clustering
############################################

# --- OPTIONAL ---
variable "node_type" {
  description = <<-EOT
    Azure Managed Redis SKU. Named node_type (rather than sku_name) to
    match the naming this repo's GCP sibling module uses for the same
    concept — it maps directly onto the azurerm_managed_redis resource's
    own sku_name argument in main.tf, which is not itself renameable
    (that's the provider's argument name, fixed by its schema).

    Please select one of the Balanced_Bxx sku options unless advised by
    engineering or Redis support. Default (when left null): the
    per-environment value in local.defaults.environment_profile — dev=
    Balanced_B0, qa/uat/prod=Balanced_B3 — in all-locals.tf. Changing this
    on an existing instance forces replacement (Azure API behavior, not a
    module limitation).
  EOT
  type        = string
  default     = null
  nullable    = true

  validation {
    condition = var.node_type == null ? true : contains([
      # Enterprise SKUs
      "Enterprise_E1", "Enterprise_E5", "Enterprise_E10", "Enterprise_E20",
      "Enterprise_E50", "Enterprise_E100", "Enterprise_E200", "Enterprise_E400",
      # Enterprise Flash SKUs
      "EnterpriseFlash_F300", "EnterpriseFlash_F700", "EnterpriseFlash_F1500",
      # Balanced SKUs
      "Balanced_B0", "Balanced_B1", "Balanced_B3", "Balanced_B5", "Balanced_B10",
      "Balanced_B20", "Balanced_B50", "Balanced_B100", "Balanced_B150",
      "Balanced_B250", "Balanced_B350", "Balanced_B500", "Balanced_B700", "Balanced_B1000",
      # Memory Optimized SKUs
      "MemoryOptimized_M10", "MemoryOptimized_M20", "MemoryOptimized_M50",
      "MemoryOptimized_M100", "MemoryOptimized_M150", "MemoryOptimized_M250",
      "MemoryOptimized_M350", "MemoryOptimized_M500", "MemoryOptimized_M700",
      "MemoryOptimized_M1000", "MemoryOptimized_M1500", "MemoryOptimized_M2000",
      # Compute Optimized SKUs
      "ComputeOptimized_X3", "ComputeOptimized_X5", "ComputeOptimized_X10",
      "ComputeOptimized_X20", "ComputeOptimized_X50", "ComputeOptimized_X100",
      "ComputeOptimized_X150", "ComputeOptimized_X250", "ComputeOptimized_X350",
      "ComputeOptimized_X500", "ComputeOptimized_X700",
      # Flash Optimized SKUs
      "FlashOptimized_A250", "FlashOptimized_A500", "FlashOptimized_A700",
      "FlashOptimized_A1000", "FlashOptimized_A1500", "FlashOptimized_A2000", "FlashOptimized_A4500",
    ], var.node_type)
    error_message = "node_type must be a valid Azure Redis Enterprise SKU. See https://learn.microsoft.com/en-us/azure/redis/how-to-scale for valid options."
  }
}

# --- OPTIONAL ---
variable "high_availability_enabled" {
  description = "Optional override for zone/HA redundancy. Default (when left null): the deployment_topology-driven value in local.defaults.topology_profile — false for STANDALONE, true for HA/DR-ActivePassive/DR-ActiveActive. Overriding this independently of deployment_topology is supported but unusual; prefer changing deployment_topology instead."
  type        = bool
  default     = null
  nullable    = true
}

# --- OPTIONAL ---
variable "clustering_policy" {
  description = "Optional override for default_database clustering_policy. Default (when left null): the deployment_topology-driven value in local.defaults.topology_profile — NoCluster for STANDALONE, OSSCluster for HA/DR-ActivePassive/DR-ActiveActive."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.clustering_policy == null ? true : contains(["NoCluster", "OSSCluster"], var.clustering_policy)
    error_message = "clustering_policy must be 'NoCluster' or 'OSSCluster'."
  }
}

# --- OPTIONAL ---
variable "eviction_policy" {
  description = "Eviction policy applied identically to the primary and DR default databases. Default (see all-locals.tf): AllKeysLRU."
  type        = string
  default     = null
  nullable    = true
}

############################################
# Auth mode & TLS
#
# TLS is non-negotiable (see client_protocol below); authorization_mode
# is a real choice, unlike this repo's GCP sibling module where
# authorization_mode only ever accepts one value. The difference is
# deliberate, not an inconsistency — see authorization_mode's description.
############################################

# --- OPTIONAL ---
variable "authorization_mode" {
  description = <<-EOT
    Client authentication mode, mapped onto default_database's real
    access_keys_authentication_enabled argument. Default (when left
    null): AccessKey.
      AccessKey: access-key (password) authentication is enabled — the
        conventional Redis AUTH flow. Fully usable end-to-end through
        Terraform today.
      MicrosoftEntraID: access-key authentication is disabled
        (access_keys_authentication_enabled = false); clients must
        authenticate via Microsoft Entra ID instead. Azure supports this
        (see https://learn.microsoft.com/en-us/azure/redis/entra-for-authentication),
        but as of this module's azurerm provider version there is no
        Terraform resource to grant specific principals data-plane access
        — that authorization step happens outside Terraform (Azure
        Portal/CLI) after this module creates the instance. Do not set
        this to MicrosoftEntraID until that out-of-band grant is part of
        your provisioning process, or no client will be able to connect.
    This module does not default to MicrosoftEntraID the way the GCP
    sibling module hard-locks its authorization_mode to IAM_AUTH — that
    module's Terraform provider can fully automate IAM role bindings,
    Azure's cannot yet automate the equivalent Entra ID grant, so forcing
    the more-automatable option as the default (not the only option) is
    the honest tradeoff today. Revisit this once the azurerm provider
    supports it end-to-end.
  EOT
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.authorization_mode == null ? true : contains(["AccessKey", "MicrosoftEntraID"], var.authorization_mode)
    error_message = "authorization_mode must be 'AccessKey' or 'MicrosoftEntraID'."
  }
}

# --- OPTIONAL ---
variable "client_protocol" {
  description = "Client protocol for the default database. This module accepts only 'Encrypted' — there is no supported way to create an instance with in-transit encryption disabled through this module. Leave unset to get 'Encrypted' (the only accepted value) by default, or set it explicitly for clarity in state/plan output."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.client_protocol == null ? true : var.client_protocol == "Encrypted"
    error_message = "client_protocol must be 'Encrypted' (or unset, which defaults to 'Encrypted') — this module does not support 'Plaintext'. Every instance created by this module requires in-transit encryption; there is no override for this."
  }
}

# --- OPTIONAL ---
variable "public_network_access" {
  description = "Public network access for Redis instances. This module accepts only 'Disabled' — there is no supported way to expose an instance to the public internet through this module. Leave unset to get 'Disabled' (the only accepted value) by default, or set it explicitly for clarity in state/plan output."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.public_network_access == null ? true : var.public_network_access == "Disabled"
    error_message = "public_network_access must be 'Disabled' (or unset, which defaults to 'Disabled') — this module does not support 'Enabled'. Every instance created by this module is private-endpoint-only; there is no override for this."
  }
}

############################################
# Persistence
#
# Azure does not allow persistence to be enabled on a geo-replicated
# database, so persistence_mode is automatically forced to DISABLED when
# DR-ActiveActive geo-replication is in effect (see
# local.persistence_mode_effective in all-locals.tf). The
# persistence_disabled_for_active_active check below warns when that
# silent override actually changes what was requested.
############################################

# --- OPTIONAL ---
variable "persistence_mode" {
  description = "Data persistence strategy. RDB = periodic point-in-time snapshots (persistence_rdb_frequency applies). AOF = append-only log of every write, higher durability (persistence_aof_frequency applies). DISABLED = no persistence. Default (see all-locals.tf): DISABLED. Forced to DISABLED whenever deployment_topology = DR-ActiveActive, regardless of this value."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.persistence_mode == null ? true : contains(["RDB", "AOF", "DISABLED"], var.persistence_mode)
    error_message = "persistence_mode must be one of: RDB, AOF, DISABLED."
  }
}

# --- OPTIONAL ---
variable "persistence_rdb_frequency" {
  description = "RDB snapshot frequency when persistence_mode = RDB. Valid values: 1h, 6h, 12h. Default (see all-locals.tf): 12h."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.persistence_rdb_frequency == null ? true : contains(["1h", "6h", "12h"], var.persistence_rdb_frequency)
    error_message = "persistence_rdb_frequency must be one of: 1h, 6h, 12h."
  }
}

# --- OPTIONAL ---
variable "persistence_aof_frequency" {
  description = "AOF fsync frequency when persistence_mode = AOF. Valid values: always, 1s. Default (see all-locals.tf): 1s."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.persistence_aof_frequency == null ? true : contains(["always", "1s"], var.persistence_aof_frequency)
    error_message = "persistence_aof_frequency must be 'always' or '1s'."
  }
}

############################################
# Deletion Protection
#
# azurerm_managed_redis has no deletion_protection_enabled argument of its
# own (unlike GCP's google_memorystore_instance) — this module's
# equivalent is an azurerm_management_lock (scope = CanNotDelete) applied
# to the instance(s) in main.tf, not an inline resource attribute. It
# blocks delete via Portal/CLI/API/Terraform alike for anyone without
# Microsoft.Authorization/locks/delete on that scope — functionally
# equivalent protection, just a separate resource rather than a flag.
############################################

# --- OPTIONAL ---
variable "deletion_protection_enabled" {
  description = "If true, an azurerm_management_lock (CanNotDelete) is created on the primary (and DR, if present) Redis instance, blocking deletion until the lock is removed. Default (see all-locals.tf): true — this module is meant for production; set to false explicitly for short-lived test instances."
  type        = bool
  default     = null
  nullable    = true
}

############################################
# Timeouts
############################################

# --- OPTIONAL ---
variable "create_timeout" {
  description = "Set to NNm or Nh values to override creation timeout defaults and avoid creation issues due to cloud provider speed. Default (see all-locals.tf): 60m."
  type        = string
  default     = null
  nullable    = true
}

############################################
# Cross-field checks — these validate combinations of EFFECTIVE
# (post-default) values in all-locals.tf, not raw var.* inputs, since a
# variable left null here no longer means "unset" — it means "use the
# centralized default."
############################################

check "dr_requires_location" {
  assert {
    condition     = local.valid_dr_location_for_dr
    error_message = "deployment_topology = '${local.deployment_topology}' requires dr_location to be set."
  }
}

check "private_endpoint_requires_subnet" {
  assert {
    condition     = local.valid_subnet_for_private_endpoint
    error_message = "create_private_endpoint resolved to true but no subnet was supplied: set subnet_id, or all of subnet_name/vnet_name/vnet_resource_group_name."
  }
}

check "private_dns_zone_link_requires_vnet_id" {
  assert {
    condition     = local.valid_vnet_id_for_dns_link
    error_message = "create_private_dns_zone and private_dns_zone_vnet_link_enabled both resolved to true, but vnet_id was not supplied; the new DNS zone will not resolve inside the VNet."
  }
}

check "persistence_disabled_for_active_active" {
  assert {
    condition     = !(local.persistence_mode != "DISABLED" && local.create_geo_replication)
    error_message = "persistence_mode = '${local.persistence_mode}' was requested but deployment_topology = DR-ActiveActive enables geo-replication, and Azure does not support persistence on geo-replicated databases. persistence_mode has been silently forced to DISABLED for this apply (see local.persistence_mode_effective) — switch to DR-ActivePassive, or set persistence_mode = DISABLED, to remove this warning."
  }
}

check "prod_should_not_be_standalone" {
  assert {
    condition     = !(local.is_prod && local.deployment_topology == "STANDALONE")
    error_message = "environment = prod with deployment_topology = STANDALONE has no HA and no DR. If this is intentional (e.g. a short-lived prod-parity test), this check is advisory only and does not block the apply."
  }
}

check "dr_subnet_inputs_complete" {
  assert {
    condition     = local.valid_dr_subnet_inputs
    error_message = "dr_subnet_name was set without both dr_vnet_name and dr_vnet_resource_group_name — the DR subnet lookup cannot resolve. Either supply all three, or use dr_subnet_id directly."
  }
}

check "dr_private_dns_zone_link_requires_vnet_id" {
  assert {
    condition     = local.valid_dr_vnet_id_for_dns_link
    error_message = "A DR private endpoint was created and create_private_dns_zone/private_dns_zone_vnet_link_enabled both resolved to true, but dr_vnet_id could not be resolved — DR clients will not be able to resolve the Redis hostname through this zone. Supply dr_vnet_id, or dr_vnet_name + dr_vnet_resource_group_name."
  }
}

check "entra_id_auth_requires_manual_grant" {
  assert {
    condition     = local.authorization_mode != "MicrosoftEntraID"
    error_message = "authorization_mode = MicrosoftEntraID disables access-key authentication, but this module's azurerm provider version has no resource to grant Entra ID principals data-plane access — that grant must be done out-of-band (Azure Portal/CLI) or no client will be able to connect. This check is advisory only and does not block the apply; it exists so this isn't missed."
  }
}
