############################################
# Instance outputs
############################################

output "redis_primary_id" {
  description = "Resource ID of the primary Managed Redis instance."
  value       = azurerm_managed_redis.primary.id
}

output "redis_primary_hostname" {
  description = "Hostname of the primary Managed Redis instance."
  value       = azurerm_managed_redis.primary.hostname
}

output "redis_primary_access_key" {
  description = "Primary access key for the primary instance's default database. Null when authorization_mode = MicrosoftEntraID (access keys are disabled). Verify this attribute path against your installed azurerm provider version before relying on it in automation."
  value       = try(azurerm_managed_redis.primary.default_database[0].primary_access_key, null)
  sensitive   = true
}

output "resolved_environment" {
  description = "The effective environment string used to derive the default node_type (see local.defaults.environment_profile in all-locals.tf)."
  value       = local.environment
}

output "resolved_deployment_topology" {
  description = "The effective deployment topology used to derive HA/clustering/DR/geo-replication (see local.defaults.topology_profile in all-locals.tf)."
  value       = local.deployment_topology
}

output "authorization_mode" {
  description = "The effective authorization mode. If MicrosoftEntraID, remember the Entra ID data-plane grant is not automated by this module — see the authorization_mode variable and the entra_id_auth_requires_manual_grant check."
  value       = local.authorization_mode
}

output "deletion_protection_enabled" {
  description = "Whether the azurerm_management_lock deletion-protection guard is in place for this apply."
  value       = local.deletion_protection_enabled
}

# --- DR outputs ---

output "redis_dr_id" {
  description = "Resource ID of the DR Managed Redis instance. Null unless deployment_topology is DR-ActivePassive or DR-ActiveActive."
  value       = local.create_dr ? azurerm_managed_redis.dr[0].id : null
}

output "redis_dr_hostname" {
  description = "Hostname of the DR Managed Redis instance. Null unless deployment_topology is DR-ActivePassive or DR-ActiveActive."
  value       = local.create_dr ? azurerm_managed_redis.dr[0].hostname : null
}

output "geo_replication_enabled" {
  description = "Whether live geo-replication was actually provisioned for this apply (deployment_topology = DR-ActiveActive)."
  value       = local.create_geo_replication
}

output "persistence_mode" {
  description = "The persistence mode actually applied to this apply. May differ from the persistence_mode input — see the persistence_disabled_for_active_active check in variables.tf."
  value       = local.persistence_mode_effective
}

# --- Networking outputs ---

output "subnet_id" {
  description = "Subnet ID used for the primary private endpoint."
  value       = local.subnet_id
}

output "private_dns_zone_ids" {
  description = "Private DNS zone IDs associated with the private endpoint(s)."
  value       = local.private_dns_zone_ids
}

output "private_endpoint_primary_id" {
  description = "Resource ID of the primary private endpoint. Null if create_private_endpoint resolved to false."
  value       = local.create_private_endpoint ? azurerm_private_endpoint.primary[0].id : null
}

output "private_endpoint_dr_id" {
  description = "Resource ID of the DR private endpoint. Null unless created — see dr_subnet_id."
  value       = local.create_dr_private_endpoint ? azurerm_private_endpoint.dr[0].id : null
}
