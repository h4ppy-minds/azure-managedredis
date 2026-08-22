terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.50.0, < 5.0.0"
    }
  }
}

# subscription_id comes from default.json's environments.<env> block — the
# same "environment picks the account, never the request file" rule the
# GCP onboarding root uses for project_id. Credentials themselves are NOT
# set here: this relies on ambient auth (az login locally, or ARM_CLIENT_ID
# / ARM_CLIENT_SECRET / ARM_TENANT_ID env vars in CI/TFC), never a variable
# a request file could influence.
provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy = false
    }
  }

  subscription_id = local._env_infra.subscription_id
}
