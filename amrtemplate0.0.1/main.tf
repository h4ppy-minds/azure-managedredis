############################################
# Onboarding root: one JSON file per request under
# config/onboarding-files-redis/, merged with global + per-environment
# defaults in locals.tf, fed into one module call per instance.
#
# No separate alerting module call here (unlike the Valkey onboarding
# root's module.valkey_alerts) — the redis module has no alerting
# submodule yet. If/when one is added, it should follow the same split:
# its own module call, for_each over the same local.redis keys, wired to
# module.redis's own outputs rather than back to each.value, so an
# onboarding PR that only touches an alert email never plans or applies
# against the instance itself.
############################################

module "redis" {
  source = "./modules/terraform-azure-dpe-azure-managed-redis-cloud-3-0"
  #source  = "app.terraform.io/<YOUR_ORG>/managed-redis/azurerm" # replace <YOUR_ORG>; see REGISTRY_PUBLISHING.md
  #version = "~> 4.0"
  for_each = local.redis

  # --- Identity ---
  name                 = each.value.name
  location             = each.value.location
  resource_group_name  = each.value.resource_group_name
  environment          = each.value.environment
  tags                 = each.value.tags

  # --- Topology (derived in locals.tf: dr_location via the region-pair
  # table, everything else is request-settable directly) ---
  deployment_topology        = each.value.deployment_topology
  dr_location                 = try(each.value.dr_location, null)
  geo_replication_group_name  = try(each.value.geo_replication_group_name, null)

  # --- Sizing ---
  node_type = each.value.node_type

  # --- Networking — always environment infra (see locals.tf Layer 3),
  # never instance-settable. create_private_endpoint left at the
  # module's own default (true) — this onboarding flow does not
  # currently offer a way to opt out of private networking; any request
  # needing that is a case for calling the module directly, not a
  # request-file field. ---
  subnet_name               = each.value.subnet_name
  vnet_name                 = each.value.vnet_name
  vnet_resource_group_name  = each.value.vnet_resource_group_name
  vnet_id                   = null # resolved by the module itself from vnet_name/vnet_resource_group_name

  dr_subnet_name               = try(each.value.dr_subnet_name, null)
  dr_vnet_name                 = try(each.value.dr_vnet_name, null)
  dr_vnet_resource_group_name  = try(each.value.dr_vnet_resource_group_name, null)

  # --- Auth / TLS ---
  # client_protocol / public_network_access are intentionally NOT passed
  # here — the module hard-requires Encrypted / Disabled and rejects any
  # other value via variable validation, so there's nothing for this
  # template to override. authorization_mode IS passed through, since
  # the module treats it as a real, overridable choice.
  authorization_mode = each.value.authorization_mode

  # --- Persistence ---
  persistence_mode          = each.value.persistence_mode
  persistence_rdb_frequency = try(each.value.persistence_rdb_frequency, null)
  persistence_aof_frequency = try(each.value.persistence_aof_frequency, null)

  eviction_policy = each.value.eviction_policy

  # --- Deletion protection ---
  deletion_protection_enabled = each.value.deletion_protection_enabled
}
