terraform {
  required_version = ">= 1.5.0" # 1.5+ needed for `check` blocks used in variables.tf

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.50.0, < 5.0.0" # 4.50+ required for the azurerm_managed_redis resource
    }
  }
}

# Deliberately no `provider "azurerm" {}` block here. A reusable module
# should never configure — or accept subscription_id/client_id/client_secret
# for — the provider its caller uses; that's the root module's job. See
# README.md "Provider configuration moved to the caller" for the v3.0.0
# migration this implies if you're upgrading from this module's v2.x.
