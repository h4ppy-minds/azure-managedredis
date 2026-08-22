############################################
# Private DNS zone
#
# create_private_dns_zone = true (default): module creates and owns
# privatelink.redis.azure.net and links it to local.vnet_id.
# create_private_dns_zone = false: bring your own zone(s) via
# var.private_dns_zone_ids (e.g. a shared hub zone managed elsewhere).
############################################

resource "azurerm_private_dns_zone" "private_dns" {
  count = local.create_private_endpoint && local.create_private_dns_zone ? 1 : 0

  name                = "privatelink.redis.azure.net"
  resource_group_name = var.resource_group_name
  tags                = local.tags
}

# NOTE: private_dns_zone_id (not resource_group_name + private_dns_zone_name)
# is the argument shape this resource actually expects on current azurerm
# provider versions — an earlier draft of this file used the older
# resource_group_name/private_dns_zone_name pair and failed
# terraform validate with "Unsupported argument" / "Missing required
# argument" for exactly this reason.
resource "azurerm_private_dns_zone_virtual_network_link" "private_dns_link" {
  count = local.create_private_endpoint && local.create_private_dns_zone && local.private_dns_zone_vnet_link_enabled ? 1 : 0

  name                 = "link-${var.name}-${local.environment}"
  private_dns_zone_id  = azurerm_private_dns_zone.private_dns[0].id
  virtual_network_id   = local.vnet_id
  registration_enabled = false
  tags                 = local.tags

  lifecycle {
    precondition {
      condition     = local.valid_vnet_id_for_dns_link
      error_message = "private_dns_zone_vnet_link_enabled resolved to true but vnet_id could not be resolved — supply vnet_id directly, or vnet_name + vnet_resource_group_name."
    }
  }
}

# DR-region VNet link — a second link on the SAME zone, so DR-region
# clients can resolve the Redis hostname too. Only created once a DR
# private endpoint actually exists (see local.create_dr_private_endpoint)
# and a DR-region VNet was resolvable.
resource "azurerm_private_dns_zone_virtual_network_link" "private_dns_link_dr" {
  count = local.create_dr_private_endpoint && local.create_private_dns_zone && local.private_dns_zone_vnet_link_enabled ? 1 : 0

  name                 = "link-${var.name}-${local.environment}-dr"
  private_dns_zone_id  = azurerm_private_dns_zone.private_dns[0].id
  virtual_network_id   = local.dr_vnet_id
  registration_enabled = false
  tags                 = local.tags

  lifecycle {
    precondition {
      condition     = local.valid_dr_vnet_id_for_dns_link
      error_message = "A DR private endpoint exists and private_dns_zone_vnet_link_enabled resolved to true, but dr_vnet_id could not be resolved — supply dr_vnet_id directly, or dr_vnet_name + dr_vnet_resource_group_name."
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
# and the caller supplied a DR-region subnet — either directly
# (dr_subnet_id) or via name-based lookup (dr_subnet_name + dr_vnet_name +
# dr_vnet_resource_group_name). subnet_id reads the RESOLVED
# local.dr_subnet_id (not var.dr_subnet_id directly) so the name-based
# lookup path actually gets used — an earlier version of this file read
# var.dr_subnet_id here, which meant the DR endpoint silently never got
# created for anyone using name-based lookup instead of a raw ID.
############################################

resource "azurerm_private_endpoint" "dr" {
  count = local.create_dr_private_endpoint ? 1 : 0

  name                = "pe-${var.name}-${local.environment}-dr"
  location            = coalesce(var.dr_location, var.location)
  resource_group_name = var.resource_group_name
  subnet_id           = local.dr_subnet_id
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
