output "redis-instances" {
  description = "One entry per onboarding request that's enabled for this environment (request_type != delete, environment == var.env)."
  value = {
    for key, inst in module.redis : key => {
      redis-primary-id             = inst["redis-primary-id"]
      redis-primary-hostname       = inst["redis-primary-hostname"]
      redis-primary-port           = inst["redis-primary-port"]
      resolved-environment         = inst["resolved-environment"]
      resolved-deployment-topology = inst["resolved-deployment-topology"]
      authorization-mode           = inst["authorization-mode"]
      deletion-protection-enabled  = inst["deletion-protection-enabled"]

      redis-dr-id             = inst["redis-dr-id"]
      redis-dr-hostname       = inst["redis-dr-hostname"]
      redis-dr-port           = inst["redis-dr-port"]
      geo-replication-enabled = inst["geo-replication-enabled"]
      persistence-mode        = inst["persistence-mode"]

      redis-modules     = inst["redis-modules"]
      clustering-policy = inst["clustering-policy"]
      eviction-policy   = inst["eviction-policy"]

      subnet-id                   = inst["subnet-id"]
      private-endpoint-primary-id = inst["private-endpoint-primary-id"]
      private-endpoint-dr-id      = inst["private-endpoint-dr-id"]
    }
  }
}

output "redis-primary-access-keys" {
  description = "Primary access key per onboarded instance, keyed the same way as redis-instances. Sensitive — null for any instance using authorization-mode = MicrosoftEntraID."
  value       = { for key, inst in module.redis : key => inst["redis-primary-access-key"] }
  sensitive   = true
}

output "derived-config-by-instance" {
  description = "Debug helper: shows the dr-location, tags, redis-modules and eviction-policy that locals.tf derived for each onboarded instance, before it was even sent to the module — useful for reviewing an onboarding PR's actual effect without running plan."
  value = {
    for name, cfg in local.redis : name => {
      deployment-topology = cfg["deployment-topology"]
      dr-location         = cfg["dr-location"]
      tags                = cfg.tags
      redis-modules       = cfg["redis-modules"]
      eviction-policy     = cfg["eviction-policy"]
    }
  }
}
