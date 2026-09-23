terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 5.0" }
    random  = { source = "hashicorp/random", version = "~> 3.6" }
  }

  # Remote state — bootstrap a storage account once, then uncomment.
  # backend "azurerm" {
  #   resource_group_name  = "tfstate-rg"
  #   storage_account_name = "acptfstate<suffix>"
  #   container_name       = "tfstate"
  #   key                  = "azure-container-platform.tfstate"
  #   use_azuread_auth     = true
  # }
}

provider "azurerm" {
  # Required from provider v4 onward — no more implicit "whatever az-cli is on".
  subscription_id = var.subscription_id

  features {
    key_vault {
      purge_soft_delete_on_destroy = false
    }
  }
}
