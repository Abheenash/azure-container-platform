# The AWS side runs tasks in private subnets with VPC endpoints so nothing needs a
# NAT gateway. Azure's shape is different: the Container Apps environment is
# injected into a delegated subnet, and private access to Cosmos is a private
# endpoint in a second subnet. Notes on why in docs/aws-vs-azure.md.

resource "azurerm_virtual_network" "main" {
  name                = "${local.name}-vnet"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  address_space       = ["10.20.0.0/16"]
  tags                = local.tags
}

# Container Apps requires a dedicated, delegated subnet. A workload profiles
# environment needs at least a /27; /23 leaves room to grow without a rebuild.
resource "azurerm_subnet" "apps" {
  name                 = "snet-apps"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.20.0.0/23"]

  delegation {
    name = "container-apps"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "endpoints" {
  name                 = "snet-endpoints"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.20.2.0/24"]
}

# Private DNS is what actually makes a private endpoint work — without the zone
# link, the app resolves the Cosmos public name and never uses the private IP.
resource "azurerm_private_dns_zone" "cosmos" {
  name                = "privatelink.documents.azure.com"
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "cosmos" {
  name                 = "${local.name}-cosmos-link"
  private_dns_zone_id  = azurerm_private_dns_zone.cosmos.id
  virtual_network_id   = azurerm_virtual_network.main.id
  registration_enabled = false
  tags                 = local.tags
}

resource "azurerm_private_endpoint" "cosmos" {
  name                = "${local.name}-cosmos-pe"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  subnet_id           = azurerm_subnet.endpoints.id
  tags                = local.tags

  private_service_connection {
    name                           = "cosmos"
    private_connection_resource_id = azurerm_cosmosdb_account.main.id
    subresource_names              = ["Sql"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "cosmos"
    private_dns_zone_ids = [azurerm_private_dns_zone.cosmos.id]
  }
}
