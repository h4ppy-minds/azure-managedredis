############################################
# Onboarding root: one JSON file per request under
# config/onboarding-files-redis/, merged with global + per-environment
# defaults in locals.tf, fed into one module call per instance.
#
# Every module argument below matches local.redis's own kebab-case keys
# almost verbatim (see locals.tf Layer 3) — the module's public interface
# is kebab-case as of v5.0.0, and this root's staging map was built to
# mirror it 1:1 rather than translating names again here.
#
# No separate alerting module call here — the redis module has no
# alerting submodule yet. If/when one is added, it should follow the same
# split: its own module call, for_each over the same local.redis keys,
# wired to module.redis's own outputs rather than back to each.value.
############################################

module "redis" {
  source = "./modules/terraform-azure-dpe-azure-managed-redis-cloud-3-0"
  #source  = "app.terraform.io/<YOUR_ORG>/managed-redis/azurerm" # replace <YOUR_ORG>; see REGISTRY_PUBLISHING.md
  #version = "~> 5.0"
  for_each = local.redis

  # --- Identity ---
  name                = each.value.name
  location            = each.value.location
  resource-group-name = each.value.resource-group-name
  environment         = each.value.environment
  tags                = each.value.tags

  # --- Topology ---
  deployment-topology        = each.value.deployment-topology
  dr-location                = try(each.value.dr-location, null)
  geo-replication-group-name = each.value.geo-replication-group-name

  # --- Sizing — always explicit; the module has no default of its own
  # any more (v5.0.0), so local.redis always resolves a real value
  # (falling back to default.json.node_type when a request omits it).
  node-type = each.value.node-type

  # --- Networking — always environment infra (see locals.tf Layer 3).
  # Every instance gets a private endpoint unconditionally (no
  # create-private-endpoint toggle any more), so subnet info is always
  # required here, not best-effort. No vnet-id / DNS-zone arguments —
  # the module no longer creates or links a private DNS zone; DNS
  # resolution for these private endpoints is handled by Infoblox
  # outside Terraform. ---
  subnet-name              = each.value.subnet-name
  vnet-name                = each.value.vnet-name
  vnet-resource-group-name = each.value.vnet-resource-group-name

  dr-resource-group-name      = try(each.value.dr-resource-group-name, null)
  dr-subnet-name              = try(each.value.dr-subnet-name, null)
  dr-vnet-name                = try(each.value.dr-vnet-name, null)
  dr-vnet-resource-group-name = try(each.value.dr-vnet-resource-group-name, null)

  # --- Auth / TLS ---
  # client-protocol / public-network-access are intentionally NOT passed
  # — the module hard-requires Encrypted / Disabled. authorization-mode
  # IS passed through, since the module treats it as a real, overridable
  # choice.
  authorization-mode = each.value.authorization-mode

  # --- Persistence ---
  persistence-mode          = each.value.persistence-mode
  persistence-rdb-frequency = try(each.value.persistence-rdb-frequency, null)
  persistence-aof-frequency = try(each.value.persistence-aof-frequency, null)

  eviction-policy = each.value.eviction-policy

  # --- Redis modules — e.g. ["RediSearch", "RedisJSON", "Bloom",
  # "TimeSeries"]. Validated and normalised by the module itself (names,
  # duplicates, DR-ActiveActive and SKU compatibility); RediSearch also
  # forces EnterpriseCluster + NoEviction there. Create-time only:
  # changing either value on an existing instance forces replacement. ---
  redis-modules     = each.value.redis-modules
  redis-module-args = each.value.redis-module-args

  # --- Deletion protection ---
  deletion-protection-enabled = each.value.deletion-protection-enabled
}
