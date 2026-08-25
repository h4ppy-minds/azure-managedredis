############################################
# Instance outputs
############################################

output "redis-primary-id" {
  description = "Resource ID of the primary Managed Redis instance."
  value       = azurerm_managed_redis.primary.id
}

output "redis-primary-hostname" {
  description = "Hostname of the primary Managed Redis instance."
  value       = azurerm_managed_redis.primary.hostname
}

output "redis-primary-port" {
  description = "Port for the primary instance's default database (typically 10000 for Managed Redis)."
  value       = try(azurerm_managed_redis.primary.default_database[0].port, null)
}

output "redis-primary-access-key" {
  description = "Primary access key for the primary instance's default database. Null when authorization-mode = MicrosoftEntraID (access keys are disabled). Verify this attribute path against your installed azurerm provider version before relying on it in automation."
  value       = try(azurerm_managed_redis.primary.default_database[0].primary_access_key, null)
  sensitive   = true
}

output "resolved-environment" {
  description = "The effective environment string used for naming."
  value       = local.environment
}

output "resolved-deployment-topology" {
  description = "The effective deployment topology used to derive HA/clustering/DR/geo-replication."
  value       = local.deployment-topology
}

output "authorization-mode" {
  description = "The effective authorization mode. If MicrosoftEntraID, remember the Entra ID data-plane grant is not automated by this module."
  value       = local.authorization-mode
}

output "deletion-protection-enabled" {
  description = "Whether the azurerm_management_lock deletion-protection guard is in place for this apply."
  value       = local.deletion-protection-enabled
}

# --- DR outputs ---

output "redis-dr-id" {
  description = "Resource ID of the DR Managed Redis instance. Null unless deployment-topology is DR-ActivePassive or DR-ActiveActive."
  value       = local.create-dr ? azurerm_managed_redis.dr[0].id : null
}

output "redis-dr-hostname" {
  description = "Hostname of the DR Managed Redis instance. Null unless deployment-topology is DR-ActivePassive or DR-ActiveActive."
  value       = local.create-dr ? azurerm_managed_redis.dr[0].hostname : null
}

output "redis-dr-port" {
  description = "Port for the DR instance's default database. Null unless deployment-topology is DR-ActivePassive or DR-ActiveActive."
  value       = local.create-dr ? try(azurerm_managed_redis.dr[0].default_database[0].port, null) : null
}

output "geo-replication-enabled" {
  description = "Whether live geo-replication was actually provisioned for this apply (deployment-topology = DR-ActiveActive)."
  value       = local.create-geo-replication
}

output "persistence-mode" {
  description = "The persistence mode actually applied to this apply. May differ from the persistence-mode input — see the persistence-disabled-for-active-active check in variables.tf."
  value       = local.persistence-mode-effective
}

# --- Networking outputs ---

output "subnet-id" {
  description = "Subnet ID used for the primary private endpoint."
  value       = local.subnet-id
}

output "private-endpoint-primary-id" {
  description = "Resource ID of the primary private endpoint (always created)."
  value       = azurerm_private_endpoint.primary.id
}

output "private-endpoint-dr-id" {
  description = "Resource ID of the DR private endpoint. Null unless deployment-topology is DR-ActivePassive or DR-ActiveActive."
  value       = local.create-dr ? azurerm_private_endpoint.dr[0].id : null
}
