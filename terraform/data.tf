# Cosmos DB for NoSQL in serverless mode — the closest thing Azure has to
# DynamoDB on-demand: pay per request, no provisioned throughput to guess.
resource "azurerm_cosmosdb_account" "main" {
  name                = "${local.name}-cosmos-${local.suffix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  offer_type          = "Standard"
  kind                = "GlobalDocumentDB"
  free_tier_enabled   = false

  # Keys off entirely: the app authenticates with its managed identity and Cosmos
  # data-plane RBAC. A connection string cannot leak if one never exists.
  local_authentication_enabled = false

  # Block writes to key metadata through the management plane, so nobody can
  # regenerate a key and quietly re-enable a credential path. (Checkov flags this
  # account under CKV_AZURE_140 regardless — see .checkov.yaml for why.)
  access_key_metadata_writes_enabled = false

  # The private endpoint is the only way in.
  public_network_access_enabled = false

  capabilities {
    name = "EnableServerless"
  }

  consistency_policy {
    consistency_level = "Session"
  }

  geo_location {
    location          = azurerm_resource_group.main.location
    failover_priority = 0
  }

  backup {
    type = "Continuous"
    tier = "Continuous7Days"
  }

  tags = local.tags
}

resource "azurerm_cosmosdb_sql_database" "notes" {
  name                = "notes"
  resource_group_name = azurerm_resource_group.main.name
  account_name        = azurerm_cosmosdb_account.main.name
}

resource "azurerm_cosmosdb_sql_container" "notes" {
  name                  = "notes"
  resource_group_name   = azurerm_resource_group.main.name
  account_name          = azurerm_cosmosdb_account.main.name
  database_name         = azurerm_cosmosdb_sql_database.notes.name
  partition_key_paths   = ["/id"]
  partition_key_version = 2

  indexing_policy {
    indexing_mode = "consistent"
    included_path {
      path = "/*"
    }
  }
}
