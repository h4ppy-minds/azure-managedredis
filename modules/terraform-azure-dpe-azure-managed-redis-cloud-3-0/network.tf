############################################
# Private endpoints.
#
# This module does NOT create or link a private DNS zone (removed in
# v5.0.0). DNS resolution for these private endpoints is handled by
# infrastructure automation outside this module (Infoblox) — see README
# "DNS is not this module's job." There is accordingly no
# private_dns_zone_group block on either endpoint below.
#
# A private endpoint is ALWAYS created for every instance — primary
# unconditionally, DR whenever the topology has one. There is no toggle
# to opt out of either; see the removed create-private-endpoint variable
# in the CHANGELOG if migrating from an earlier version.
############################################

resource "azurerm_private_endpoint" "primary" {
  name                = "pe-${var.name}-${local.environment}"
  location            = var.location
  resource_group_name = var.resource-group-name
  subnet_id           = local.subnet-id
  tags                = local.tags

  private_service_connection {
    name                           = "psc-${var.name}-${local.environment}"
    private_connection_resource_id = azurerm_managed_redis.primary.id
    subresource_names              = ["redisenterprise"]
    is_manual_connection           = false
  }

  lifecycle {
    ignore_changes = [tags] # see main.tf's note on tag preservation

    precondition {
      condition     = local.valid-subnet-for-private-endpoint
      error_message = "No subnet could be resolved for the primary private endpoint. Set subnet-id, or all of subnet-name/vnet-name/vnet-resource-group-name."
    }
  }
}

resource "azurerm_private_endpoint" "dr" {
  count = local.create-dr ? 1 : 0

  name                = "pe-${var.name}-${local.environment}-dr"
  location            = coalesce(var.dr-location, var.location)
  resource_group_name = var.resource-group-name
  subnet_id           = local.dr-subnet-id
  tags                = local.tags

  private_service_connection {
    name                           = "psc-${var.name}-${local.environment}-dr"
    private_connection_resource_id = azurerm_managed_redis.dr[0].id
    subresource_names              = ["redisenterprise"]
    is_manual_connection           = false
  }

  lifecycle {
    ignore_changes = [tags] # see main.tf's note on tag preservation

    precondition {
      condition     = local.valid-dr-subnet-inputs
      error_message = "deployment-topology = '${local.deployment-topology}' creates a DR instance, which always gets a private endpoint. Set dr-subnet-id, or all of dr-subnet-name/dr-vnet-name/dr-vnet-resource-group-name."
    }
  }
}
