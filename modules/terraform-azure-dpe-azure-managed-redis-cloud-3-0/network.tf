############################################
# Private endpoints.
#
# This module does NOT create or link a private DNS zone itself (removed
# in v5.0.0) — DNS resolution for these private endpoints is handled by
# infrastructure automation outside this module (Infoblox). That
# automation attaches a private_dns_zone_group to each endpoint AFTER
# Terraform creates it — out-of-band, not through this config. Both
# endpoints below therefore ignore_changes on private_dns_zone_group:
# without that, every plan would see Infoblox's attachment as drift from
# "no private_dns_zone_group block declared here" and try to remove it,
# fighting the external automation on every single apply. (Bug found
# during integration testing — v5.1.0.)
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
    # tags: see main.tf's note on tag preservation.
    # private_dns_zone_group: Infoblox attaches this out-of-band after
    # create — without ignoring it, every plan tries to remove what
    # Infoblox just set up.
    ignore_changes = [tags, private_dns_zone_group]

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
  resource_group_name = local.dr-resource-group-name
  subnet_id           = local.dr-subnet-id
  tags                = local.tags

  private_service_connection {
    name                           = "psc-${var.name}-${local.environment}-dr"
    private_connection_resource_id = azurerm_managed_redis.dr[0].id
    subresource_names              = ["redisenterprise"]
    is_manual_connection           = false
  }

  lifecycle {
    ignore_changes = [tags, private_dns_zone_group]

    precondition {
      condition     = local.valid-dr-subnet-inputs
      error_message = "deployment-topology = '${local.deployment-topology}' creates a DR instance, which always gets a private endpoint. Set dr-subnet-id, or all of dr-subnet-name/dr-vnet-name/dr-vnet-resource-group-name."
    }
  }
}
