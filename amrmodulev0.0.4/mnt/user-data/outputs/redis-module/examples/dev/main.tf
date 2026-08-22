terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.50.0, < 5.0.0"
    }
  }
}

# Provider configuration lives HERE, in the root that calls the module —
# not inside the module itself. See the module's README for why.
provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy = false
    }
  }

  subscription_id = var.subscription_id
  client_id       = var.client_id
  tenant_id       = var.tenant_id
  client_secret   = var.client_secret
}

module "redis" {
  source = "../.." # path to the module root

  name                 = "test-build-2"
  location             = "eastus2"
  resource_group_name  = "cfes-amr-eastus2-dev-rg"
  environment          = "dev"
  deployment_topology  = "STANDALONE" # omit for the same result — STANDALONE is the module default

  # Name-based subnet lookup instead of a direct subnet_id
  subnet_name              = "cfes-amr-eastus2-dev-snet"
  vnet_name                = "az3-cfes-eastus2-npe-vnet"
  vnet_resource_group_name = "az3-network-cfes-eastus2-npe-rg"
  vnet_id                  = "/subscriptions/${var.subscription_id}/resourceGroups/az3-network-cfes-eastus2-npe-rg/providers/Microsoft.Network/virtualNetworks/az3-cfes-eastus2-npe-vnet"

  # node_type omitted -> resolves to the dev default (Balanced_B0)

  # Short-lived dev instance — safe to allow deletion without an extra step
  deletion_protection_enabled = false

  tags = {
    costcenter = "cfes"
    owner      = "platform-engineering"
  }
}
