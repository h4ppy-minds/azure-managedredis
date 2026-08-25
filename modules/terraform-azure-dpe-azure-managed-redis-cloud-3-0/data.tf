# Only queried when the caller didn't pass subnet-id directly. Every
# instance gets a private endpoint (no toggle), so this lookup is no
# longer conditioned on anything but "was an ID already given."
data "azurerm_subnet" "subnet" {
  count = var.subnet-id == null ? 1 : 0

  name                 = var.subnet-name
  virtual_network_name = var.vnet-name
  resource_group_name  = var.vnet-resource-group-name
}

# Only queried when there's a DR instance, the caller didn't pass
# dr-subnet-id directly, and a dr-subnet-name was actually given to look
# up. Keyed off the RAW var.* inputs (not a resolved local) to avoid a
# dependency cycle: local.create-dr does not itself depend on this data
# source, so this is safe.
data "azurerm_subnet" "dr-subnet" {
  count = local.create-dr && var.dr-subnet-id == null && var.dr-subnet-name != null ? 1 : 0

  name                 = var.dr-subnet-name
  virtual_network_name = var.dr-vnet-name
  resource_group_name  = var.dr-vnet-resource-group-name
}
