terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.50.0, < 5.0.0"
    }
  }
}

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
  source = "../.."

  name                 = "cfes-amr"
  location             = "eastus2"
  resource_group_name  = "cfes-amr-eastus2-prod-rg"
  environment          = "prod"
  deployment_topology  = "DR-ActiveActive"
  dr_location          = "centralus"

  geo_replication_group_name = "cfes-amr-geo"

  node_type = "Balanced_B10"

  # Primary networking
  subnet_id = "/subscriptions/${var.subscription_id}/resourceGroups/az3-network-cfes-eastus2-prod-rg/providers/Microsoft.Network/virtualNetworks/az3-cfes-eastus2-prod-vnet/subnets/cfes-amr-eastus2-prod-snet"
  vnet_id   = "/subscriptions/${var.subscription_id}/resourceGroups/az3-network-cfes-eastus2-prod-rg/providers/Microsoft.Network/virtualNetworks/az3-cfes-eastus2-prod-vnet"

  # DR networking (optional — omit dr_subnet_id to skip the DR private endpoint)
  dr_subnet_id = "/subscriptions/${var.subscription_id}/resourceGroups/az3-network-cfes-centralus-prod-rg/providers/Microsoft.Network/virtualNetworks/az3-cfes-centralus-prod-vnet/subnets/cfes-amr-centralus-prod-snet"

  # DR-ActiveActive does not support persistence — leave persistence_mode unset/DISABLED
  authorization_mode = "AccessKey" # MicrosoftEntraID requires an out-of-band grant — see variables.tf

  # deletion_protection_enabled omitted -> defaults to true (prod)

  tags = {
    costcenter = "cfes"
    owner      = "platform-engineering"
  }
}
