# Only queried when the caller didn't pass subnet_id directly — see
# local.subnet_id in all-locals.tf.
data "azurerm_subnet" "subnet" {
  count = local.create_private_endpoint && var.subnet_id == null ? 1 : 0

  name                 = var.subnet_name
  virtual_network_name = var.vnet_name
  resource_group_name  = var.vnet_resource_group_name
}

# Only queried when the caller didn't pass vnet_id directly AND actually
# supplied vnet_name to look up — see local.vnet_id in all-locals.tf.
# NOTE: this condition must check var.vnet_name != null (not == null) —
# an earlier version of the DR equivalent of this data source had that
# comparison inverted, which meant the lookup only ran when nothing was
# given to look up.
data "azurerm_virtual_network" "vnet" {
  count = (
    local.create_private_endpoint &&
    local.create_private_dns_zone &&
    local.private_dns_zone_vnet_link_enabled &&
    var.vnet_id == null && var.vnet_name != null
  ) ? 1 : 0

  name                = var.vnet_name
  resource_group_name = var.vnet_resource_group_name
}

# Only queried when the caller didn't pass dr_subnet_id directly AND gave
# us a dr_subnet_name to look up. Note this count is driven by the RAW
# var.* inputs, not local.create_dr_private_endpoint — that local is
# itself derived from these same raw inputs (see all-locals.tf), and
# keying this data source's count off local.dr_subnet_id (the RESOLVED
# value, which depends on this very data source) creates a dependency
# cycle: local.dr_subnet_id -> this data source -> local.create_dr_private_endpoint
# -> local.dr_subnet_id. Keeping this one-directional (raw inputs -> count
# -> resolved local) avoids that.
data "azurerm_subnet" "dr_subnet" {
  count = local.create_dr && (var.dr_subnet_id == null && var.dr_subnet_name != null) ? 1 : 0

  name                 = var.dr_subnet_name
  virtual_network_name = var.dr_vnet_name
  resource_group_name  = var.dr_vnet_resource_group_name
}

# Only queried when the caller didn't pass dr_vnet_id directly AND
# actually supplied dr_vnet_name to look up.
data "azurerm_virtual_network" "dr_vnet" {
  count = (
    local.create_dr &&
    local.create_private_dns_zone &&
    local.private_dns_zone_vnet_link_enabled &&
    var.dr_vnet_id == null && var.dr_vnet_name != null
  ) ? 1 : 0

  name                = var.dr_vnet_name
  resource_group_name = var.dr_vnet_resource_group_name
}
