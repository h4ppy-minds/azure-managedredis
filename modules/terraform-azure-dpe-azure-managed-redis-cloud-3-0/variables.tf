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
variable "resource-group-name" {
  description = "Resource group where every resource in this module is created."
  type        = string
}

# --- OPTIONAL ---
variable "tags" {
  description = "Tags applied to every resource this module creates. Default (see local.defaults.tags in all-locals.tf): {}. NOTE: every taggable resource in this module uses lifecycle { ignore_changes = [tags] } — tags are set on first create only and never touched by later applies, so tagging automation running outside Terraform (e.g. Infoblox, a governance/policy tool) is never reverted by a subsequent apply. This also means changing this variable on an EXISTING instance and re-applying will NOT update its tags — see main.tf/network.tf for the full note."
  type        = map(string)
  default     = null
  nullable    = true
}

# --- REQUIRED ---
variable "environment" {
  description = "Deployment environment: dev, qa, uat, or prod. Used for naming, and gates DR/geo-replication topology safety checks. Required — no sensible module-wide default exists for this."
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
variable "deployment-topology" {
  description = <<-EOT
    The single knob for topology. Default (when left null): see
    local.defaults.deployment-topology in all-locals.tf.
      STANDALONE: single instance, no HA, no DR. high_availability_enabled
        = false, clustering_policy = NoCluster.
      HA: single-region instance with HA/zone redundancy enabled, no DR.
        high_availability_enabled = true, clustering_policy = OSSCluster.
      DR-ActivePassive: adds a DR instance in dr-location. Azure Managed
        Redis has no native "passive replica" concept, so this DR instance
        is a standalone standby you keep in sync yourself (RDB/AOF export-
        import, or a secondary write path). See README "Known
        limitations."
      DR-ActiveActive: adds a DR instance in dr-location, linked to the
        primary via azurerm_managed_redis_geo_replication — live,
        bidirectional replication. Azure does not support persistence on a
        geo-replicated database, so persistence-mode is silently forced to
        DISABLED in this mode. Requires a geo-replication-capable
        node-type (Balanced_B10+ or equivalent) — see
        geo-replication-requires-supported-sku check below.
    Requires dr-location, and a DR subnet (dr-subnet-id, or dr-subnet-name
    + dr-vnet-name + dr-vnet-resource-group-name), whenever this resolves
    to one of the DR-* values — every instance this module creates gets a
    private endpoint, DR included; there is no opt-out.
  EOT
  type        = string
  default     = null
  nullable    = true

  validation {
    condition = var.deployment-topology == null ? true : contains(
      ["STANDALONE", "HA", "DR-ActivePassive", "DR-ActiveActive"],
      var.deployment-topology
    )
    error_message = "deployment-topology must be one of: STANDALONE, HA, DR-ActivePassive, DR-ActiveActive."
  }
}

# --- OPTIONAL ---
variable "dr-location" {
  description = "Azure region for the DR instance (e.g. centralus). Required whenever deployment-topology resolves to DR-ActivePassive or DR-ActiveActive (enforced by the dr-requires-location check and a matching lifecycle precondition) — no centralized default, since null is the meaningful 'no DR region chosen' state, not a value to retune."
  type        = string
  default     = null
  nullable    = true
}

# --- OPTIONAL ---
variable "dr-resource-group-name" {
  description = <<-EOT
    Resource group for the DR instance and its private endpoint. Default
    (when left null): falls back to resource-group-name — i.e. DR shares
    the primary's resource group unless you explicitly separate them.

    Production recommendation: use a SEPARATE resource group per region
    (e.g. "cfes-amr-eastus2-prod-rg" for primary, "cfes-amr-centralus-prod-rg"
    for DR) rather than the shared-RG default. This follows standard Azure
    resource-group design guidance (Cloud Adoption Framework) — resource
    groups are Azure's basic blast-radius/RBAC-scoping boundary, and a
    disaster-recovery resource logically coupled to the SAME resource
    group as the region it's meant to survive the loss of undermines the
    point of region independence. The shared-RG default exists only for
    backward compatibility with callers that haven't separated their
    resource groups by region yet.
  EOT
  type        = string
  default     = null
  nullable    = true
}

# --- OPTIONAL ---
variable "geo-replication-group-name" {
  description = "Optional name override for the geo-replication group used by DR-ActiveActive. If null, Azure generates one. Only used when deployment-topology = DR-ActiveActive."
  type        = string
  default     = null
  nullable    = true
}

############################################
# Networking
#
# A private endpoint is ALWAYS created for every instance this module
# provisions — primary and, whenever the topology has one, DR. There is no
# toggle to opt out. Subnet info is therefore always required, either as a
# direct ID or via name-based lookup.
#
# This module does NOT create or link a private DNS zone. DNS resolution
# for the private endpoint is handled by infrastructure automation outside
# this module (Infoblox) — see README "DNS is not this module's job."
############################################

# --- OPTIONAL ---
variable "subnet-id" {
  description = "Resource ID of an existing subnet for the primary private endpoint. Takes precedence over subnet-name/vnet-name/vnet-resource-group-name. Required (by one route or the other) — enforced by the private-endpoint-requires-subnet check and a matching lifecycle precondition."
  type        = string
  default     = null
  nullable    = true
}

# --- OPTIONAL ---
variable "subnet-name" {
  description = "Name of the subnet to look up when subnet-id is not supplied. Used together with vnet-name and vnet-resource-group-name."
  type        = string
  default     = null
  nullable    = true
}

# --- OPTIONAL ---
variable "vnet-name" {
  description = "Name of the virtual network containing subnet-name."
  type        = string
  default     = null
  nullable    = true
}

# --- OPTIONAL ---
variable "vnet-resource-group-name" {
  description = "Resource group containing vnet-name."
  type        = string
  default     = null
  nullable    = true
}

# --- OPTIONAL ---
variable "dr-subnet-id" {
  description = "Resource ID of the subnet in the DR region for the DR Redis private endpoint. Takes precedence over dr-subnet-name/dr-vnet-name/dr-vnet-resource-group-name. Required (by one route or the other) whenever deployment-topology resolves to a DR-* value — every DR instance gets a private endpoint the same as primary; there is no opt-out."
  type        = string
  default     = null
  nullable    = true
}

# --- OPTIONAL ---
variable "dr-subnet-name" {
  description = "Name of the DR-region subnet to look up when dr-subnet-id is not supplied. Used together with dr-vnet-name and dr-vnet-resource-group-name."
  type        = string
  default     = null
  nullable    = true
}

# --- OPTIONAL ---
variable "dr-vnet-name" {
  description = "Name of the DR-region virtual network containing dr-subnet-name."
  type        = string
  default     = null
  nullable    = true
}

# --- OPTIONAL ---
variable "dr-vnet-resource-group-name" {
  description = "Resource group containing dr-vnet-name."
  type        = string
  default     = null
  nullable    = true
}

############################################
# Sizing / HA / Clustering
############################################

# --- REQUIRED ---
variable "node-type" {
  description = <<-EOT
    Azure Managed Redis SKU. Required — this module has no per-environment
    default any more; the caller (typically an onboarding template with
    its own sizing policy) must always supply this explicitly. Please
    select one of the Balanced_Bxx options unless advised by engineering
    or Redis support. Changing this on an existing instance forces
    replacement (Azure API behavior, not a module limitation).
    deployment-topology = DR-ActiveActive requires a geo-replication-
    capable SKU — see the geo-replication-requires-supported-sku check.
  EOT
  type        = string

  validation {
    condition = contains([
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
    ], var.node-type)
    error_message = "node-type must be a valid Azure Redis Enterprise SKU. See https://learn.microsoft.com/en-us/azure/redis/how-to-scale for valid options."
  }
}

# --- OPTIONAL ---
variable "high-availability-enabled" {
  description = "Optional override for zone/HA redundancy. Default (when left null): the deployment-topology-driven value in local.defaults.topology-profile — false for STANDALONE, true for HA/DR-ActivePassive/DR-ActiveActive."
  type        = bool
  default     = null
  nullable    = true
}

# --- OPTIONAL ---
variable "clustering-policy" {
  description = "Optional override for default_database clustering_policy. Default (when left null): the deployment-topology-driven value in local.defaults.topology-profile — NoCluster for STANDALONE, OSSCluster for HA/DR-ActivePassive/DR-ActiveActive."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.clustering-policy == null ? true : contains(["NoCluster", "OSSCluster"], var.clustering-policy)
    error_message = "clustering-policy must be 'NoCluster' or 'OSSCluster'."
  }
}

# --- OPTIONAL ---
variable "eviction-policy" {
  description = "Eviction policy applied identically to the primary and DR default databases. Default (see all-locals.tf): AllKeysLRU."
  type        = string
  default     = null
  nullable    = true
}

############################################
# Auth mode & TLS
############################################

# --- OPTIONAL ---
variable "authorization-mode" {
  description = <<-EOT
    Client authentication mode, mapped onto default_database's real
    access_keys_authentication_enabled argument. Default (when left
    null): AccessKey.
      AccessKey: access-key (password) authentication is enabled.
      MicrosoftEntraID: access-key authentication is disabled; clients
        must authenticate via Microsoft Entra ID instead. This module's
        azurerm provider version has no resource to grant specific
        principals data-plane access — that authorization step happens
        outside Terraform after this module creates the instance. Do not
        set this to MicrosoftEntraID until that out-of-band grant is part
        of your provisioning process, or no client will be able to
        connect.
  EOT
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.authorization-mode == null ? true : contains(["AccessKey", "MicrosoftEntraID"], var.authorization-mode)
    error_message = "authorization-mode must be 'AccessKey' or 'MicrosoftEntraID'."
  }
}

# --- OPTIONAL ---
variable "client-protocol" {
  description = "Client protocol for the default database. This module accepts only 'Encrypted' — there is no supported way to create an instance with in-transit encryption disabled through this module."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.client-protocol == null ? true : var.client-protocol == "Encrypted"
    error_message = "client-protocol must be 'Encrypted' (or unset, which defaults to 'Encrypted') — this module does not support 'Plaintext'."
  }
}

# --- OPTIONAL ---
variable "public-network-access" {
  description = "Public network access for Redis instances. This module accepts only 'Disabled' — there is no supported way to expose an instance to the public internet through this module."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.public-network-access == null ? true : var.public-network-access == "Disabled"
    error_message = "public-network-access must be 'Disabled' (or unset, which defaults to 'Disabled') — this module does not support 'Enabled'."
  }
}

############################################
# Persistence
############################################

# --- OPTIONAL ---
variable "persistence-mode" {
  description = "Data persistence strategy. RDB = periodic point-in-time snapshots. AOF = append-only log of every write. DISABLED = no persistence. Default (see all-locals.tf): DISABLED. Forced to DISABLED whenever deployment-topology = DR-ActiveActive, regardless of this value."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.persistence-mode == null ? true : contains(["RDB", "AOF", "DISABLED"], var.persistence-mode)
    error_message = "persistence-mode must be one of: RDB, AOF, DISABLED."
  }
}

# --- OPTIONAL ---
variable "persistence-rdb-frequency" {
  description = "RDB snapshot frequency when persistence-mode = RDB. Valid values: 1h, 6h, 12h. Default (see all-locals.tf): 12h."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.persistence-rdb-frequency == null ? true : contains(["1h", "6h", "12h"], var.persistence-rdb-frequency)
    error_message = "persistence-rdb-frequency must be one of: 1h, 6h, 12h."
  }
}

# --- OPTIONAL ---
variable "persistence-aof-frequency" {
  description = "AOF fsync frequency when persistence-mode = AOF. Valid values: always, 1s. Default (see all-locals.tf): 1s."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.persistence-aof-frequency == null ? true : contains(["always", "1s"], var.persistence-aof-frequency)
    error_message = "persistence-aof-frequency must be 'always' or '1s'."
  }
}

############################################
# Deletion Protection
############################################

# --- OPTIONAL ---
variable "deletion-protection-enabled" {
  description = "If true, an azurerm_management_lock (CanNotDelete) is created on the primary (and DR, if present) Redis instance, blocking deletion until the lock is removed. Default (see all-locals.tf): true."
  type        = bool
  default     = null
  nullable    = true
}

############################################
# Timeouts
############################################

# --- OPTIONAL ---
variable "create-timeout" {
  description = "Set to NNm or Nh values to override creation timeout defaults. Default (see all-locals.tf): 60m."
  type        = string
  default     = null
  nullable    = true
}

############################################
# Cross-field checks — validate combinations of EFFECTIVE (post-default)
# values in all-locals.tf. These are advisory (a `check` block can never
# block an apply) — the ones that must actually be enforced are backed by
# a matching lifecycle.precondition in main.tf/network.tf.
############################################

check "dr-requires-location" {
  assert {
    condition     = local.valid-dr-location-for-dr
    error_message = "deployment-topology = '${local.deployment-topology}' requires dr-location to be set."
  }
}

check "private-endpoint-requires-subnet" {
  assert {
    condition     = local.valid-subnet-for-private-endpoint
    error_message = "Every instance gets a private endpoint — no subnet was supplied. Set subnet-id, or all of subnet-name/vnet-name/vnet-resource-group-name."
  }
}

check "dr-subnet-required" {
  assert {
    condition     = local.valid-dr-subnet-inputs
    error_message = "deployment-topology = '${local.deployment-topology}' creates a DR instance, and every instance gets a private endpoint — no DR subnet was supplied. Set dr-subnet-id, or all of dr-subnet-name/dr-vnet-name/dr-vnet-resource-group-name."
  }
}

check "persistence-disabled-for-active-active" {
  assert {
    condition     = !(local.persistence-mode != "DISABLED" && local.create-geo-replication)
    error_message = "persistence-mode = '${local.persistence-mode}' was requested but deployment-topology = DR-ActiveActive enables geo-replication, and Azure does not support persistence on geo-replicated databases. persistence-mode has been silently forced to DISABLED for this apply."
  }
}

check "geo-replication-requires-supported-sku" {
  assert {
    condition = !local.create-geo-replication || contains([
      "Balanced_B10", "Balanced_B20", "Balanced_B50", "Balanced_B100", "Balanced_B150",
      "Balanced_B250", "Balanced_B350", "Balanced_B500", "Balanced_B700", "Balanced_B1000",
      "ComputeOptimized_X10", "ComputeOptimized_X20", "ComputeOptimized_X50", "ComputeOptimized_X100",
      "ComputeOptimized_X150", "ComputeOptimized_X250", "ComputeOptimized_X350", "ComputeOptimized_X500",
      "ComputeOptimized_X700",
      "MemoryOptimized_M10", "MemoryOptimized_M20", "MemoryOptimized_M50", "MemoryOptimized_M100",
      "MemoryOptimized_M150", "MemoryOptimized_M250", "MemoryOptimized_M350", "MemoryOptimized_M500",
      "MemoryOptimized_M700", "MemoryOptimized_M1000", "MemoryOptimized_M1500", "MemoryOptimized_M2000",
      "FlashOptimized_A500", "FlashOptimized_A700", "FlashOptimized_A1000", "FlashOptimized_A1500",
      "FlashOptimized_A2000", "FlashOptimized_A4500",
    ], var.node-type)
    error_message = "node-type '${var.node-type}' does not support geo-replication (deployment-topology = DR-ActiveActive). Use Balanced_B10+ or a supported ComputeOptimized/MemoryOptimized/FlashOptimized SKU."
  }
}

check "prod-should-not-be-standalone" {
  assert {
    condition     = !(local.is-prod && local.deployment-topology == "STANDALONE")
    error_message = "environment = prod with deployment-topology = STANDALONE has no HA and no DR. If this is intentional (e.g. a short-lived prod-parity test), this check is advisory only and does not block the apply."
  }
}

check "entra-id-auth-requires-manual-grant" {
  assert {
    condition     = local.authorization-mode != "MicrosoftEntraID"
    error_message = "authorization-mode = MicrosoftEntraID disables access-key authentication, but this module's azurerm provider version has no resource to grant Entra ID principals data-plane access — that grant must be done out-of-band. This check is advisory only and does not block the apply."
  }
}
