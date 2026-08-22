output "redis_instances" {
  description = "One entry per onboarding request that's enabled for this environment (request_type != delete, environment == var.env)."
  value = {
    for key, inst in module.redis : key => {
      redis_primary_id             = inst.redis_primary_id
      redis_primary_hostname       = inst.redis_primary_hostname
      resolved_environment         = inst.resolved_environment
      resolved_deployment_topology = inst.resolved_deployment_topology
      authorization_mode           = inst.authorization_mode
      deletion_protection_enabled  = inst.deletion_protection_enabled

      redis_dr_id              = inst.redis_dr_id
      redis_dr_hostname        = inst.redis_dr_hostname
      geo_replication_enabled  = inst.geo_replication_enabled
      persistence_mode         = inst.persistence_mode

      subnet_id                   = inst.subnet_id
      private_dns_zone_ids        = inst.private_dns_zone_ids
      private_endpoint_primary_id = inst.private_endpoint_primary_id
      private_endpoint_dr_id      = inst.private_endpoint_dr_id
    }
  }
}

output "redis_primary_access_keys" {
  description = "Primary access key per onboarded instance, keyed the same way as redis_instances. Sensitive — null for any instance using authorization_mode = MicrosoftEntraID."
  value       = { for key, inst in module.redis : key => inst.redis_primary_access_key }
  sensitive   = true
}

output "derived_config_by_instance" {
  description = "Debug helper: shows the dr_location and tags that locals.tf derived for each onboarded instance, before it was even sent to the module — useful for reviewing an onboarding PR's actual effect without running plan."
  value = {
    for name, cfg in local.redis : name => {
      deployment_topology = cfg.deployment_topology
      dr_location          = cfg.dr_location
      tags                 = cfg.tags
    }
  }
}
