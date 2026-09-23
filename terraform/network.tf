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

# Network security groups. The AWS side has security groups on the task and the
# ALB; the GCP side gets default-deny ingress from VPC firewall rules. Azure
# subnets have NO filtering unless an NSG is attached, so without these the
# subnets are open at the network layer — which is what CKV2_AZURE_31 is about.

resource "azurerm_network_security_group" "endpoints" {
  name                = "${local.name}-nsg-endpoints"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = local.tags
}

# The private-endpoint subnet holds one thing: the Cosmos private endpoint. The
# only traffic that should reach it is TLS from the app subnet.
resource "azurerm_network_security_rule" "endpoints_allow_apps_https" {
  name                        = "allow-apps-to-cosmos"
  resource_group_name         = azurerm_resource_group.main.name
  network_security_group_name = azurerm_network_security_group.endpoints.name
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "10.20.0.0/23" # the delegated apps subnet
  destination_address_prefix  = "*"
}

resource "azurerm_network_security_rule" "endpoints_deny_all_inbound" {
  name                        = "deny-everything-else"
  resource_group_name         = azurerm_resource_group.main.name
  network_security_group_name = azurerm_network_security_group.endpoints.name
  priority                    = 4096 # the lowest evaluable priority
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
}

resource "azurerm_subnet_network_security_group_association" "endpoints" {
  subnet_id                 = azurerm_subnet.endpoints.id
  network_security_group_id = azurerm_network_security_group.endpoints.id
}

# The Container Apps subnet is deliberately NOT locked down to the same degree.
# A workload-profiles environment requires outbound to Azure control-plane
# endpoints, MCR, and Azure DNS, and an over-tight NSG there produces an
# environment that silently fails to provision rather than an obvious error.
# This attaches an NSG (so the subnet is filtered at all, which is the finding)
# and keeps the documented required traffic open.
# Reference: Microsoft's "Securing a custom VNET in Azure Container Apps".
resource "azurerm_network_security_group" "apps" {
  name                = "${local.name}-nsg-apps"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = local.tags
}

resource "azurerm_network_security_rule" "apps_allow_azure_outbound" {
  name                        = "allow-azure-cloud-outbound"
  resource_group_name         = azurerm_resource_group.main.name
  network_security_group_name = azurerm_network_security_group.apps.name
  priority                    = 100
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_ranges     = ["443", "9000", "9090"]
  source_address_prefix       = "*"
  destination_address_prefix  = "AzureCloud"
}

resource "azurerm_subnet_network_security_group_association" "apps" {
  subnet_id                 = azurerm_subnet.apps.id
  network_security_group_id = azurerm_network_security_group.apps.id
}
