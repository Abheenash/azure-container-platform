data "azurerm_client_config" "current" {}

# ACR and Cosmos account names are globally unique across all of Azure, so a
# deterministic-per-state suffix is the difference between "terraform apply" and
# "that name is taken".
resource "random_string" "suffix" {
  length  = 6
  lower   = true
  upper   = false
  numeric = true
  special = false
}

locals {
  name   = var.name_prefix
  suffix = random_string.suffix.result
  tags = {
    Project   = "azure-container-platform"
    ManagedBy = "terraform"
    Mirrors   = "secure-container-pipeline"
  }
}

resource "azurerm_resource_group" "main" {
  name     = "${local.name}-rg"
  location = var.location
  tags     = local.tags
}
