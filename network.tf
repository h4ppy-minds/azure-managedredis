############################################
# Private DNS zone
#
# create_private_dns_zone = true (default): module creates and owns
# privatelink.redis.azure.net and links it to var.vnet_id.
# create_private_dns_zone = false: bring your own zone(s) via
# var.private_dns_zone_ids (e.g. a shared hub zone managed elsewhere).
############################################

resource "azurerm_private_dns_zone" "private_dns" {
  count = local.create_private_endpoint && local.create_private_dns_zone ? 1 : 0

  name                = "privatelink.redis.azure.net"
  resource_group_name = var.resource_group_name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "private_dns_link" {
  count = local.create_private_endpoint && local.create_private_dns_zone && local.private_dns_zone_vnet_link_enabled ? 1 : 0

  name                  = "link-${var.name}-${local.environment}"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.private_dns[0].name
  virtual_network_id    = var.vnet_id
  registration_enabled  = false
  tags                  = local.tags

  lifecycle {
    precondition {
      condition     = local.valid_vnet_id_for_dns_link
      error_message = "private_dns_zone_vnet_link_enabled resolved to true but vnet_id was not supplied."
    }
  }
}

############################################
# Private endpoint — primary
############################################

resource "azurerm_private_endpoint" "primary" {
  count = local.create_private_endpoint ? 1 : 0

  name                = "pe-${var.name}-${local.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = local.subnet_id
  tags                = local.tags

  private_service_connection {
    name                           = "psc-${var.name}-${local.environment}"
    private_connection_resource_id = azurerm_managed_redis.primary.id
    subresource_names              = ["redisenterprise"]
    is_manual_connection           = false
  }

  dynamic "private_dns_zone_group" {
    for_each = length(local.private_dns_zone_ids) > 0 ? [1] : []
    content {
      name                 = "dns-${var.name}-${local.environment}"
      private_dns_zone_ids = local.private_dns_zone_ids
    }
  }
}

############################################
# Private endpoint — DR
#
# Only created when there's a DR instance, private endpoints are enabled,
# and the caller supplied a DR-region subnet via var.dr_subnet_id.
############################################

resource "azurerm_private_endpoint" "dr" {
  count = local.create_dr_private_endpoint ? 1 : 0

  name                = "pe-${var.name}-${local.environment}-dr"
  location            = coalesce(var.dr_location, var.location)
  resource_group_name = var.resource_group_name
  subnet_id           = var.dr_subnet_id
  tags                = local.tags

  private_service_connection {
    name                           = "psc-${var.name}-${local.environment}-dr"
    private_connection_resource_id = azurerm_managed_redis.dr[0].id
    subresource_names              = ["redisenterprise"]
    is_manual_connection           = false
  }

  dynamic "private_dns_zone_group" {
    for_each = length(local.private_dns_zone_ids) > 0 ? [1] : []
    content {
      name                 = "dns-${var.name}-${local.environment}-dr"
      private_dns_zone_ids = local.private_dns_zone_ids
    }
  }
}
