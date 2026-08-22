# Only queried when the caller didn't pass subnet_id directly — see
# local.subnet_id in all-locals.tf.
data "azurerm_subnet" "subnet" {
  count = local.create_private_endpoint && var.subnet_id == null ? 1 : 0

  name                 = var.subnet_name
  virtual_network_name = var.vnet_name
  resource_group_name  = var.vnet_resource_group_name
}
