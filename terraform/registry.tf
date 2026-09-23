resource "azurerm_container_registry" "main" {
  name                = "${local.name}acr${local.suffix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "Premium" # Premium unlocks quarantine + private access
  admin_enabled       = false     # no username/password pair; pulls use managed identity

  # NOTE: ACR content trust (and the provider's trust_policy_enabled argument,
  # removed in azurerm v5) is being retired by Azure. There is no ACR-native
  # "refuse unsigned images" control to replace it, so image provenance lives
  # entirely in the pipeline here — cosign signature + SLSA attestation, exactly
  # as on the AWS side. Quarantine holds a pushed image un-pullable until it has
  # passed a scan, which covers the CVE half of the same problem.
  quarantine_policy_enabled = true
  export_policy_enabled     = false
  anonymous_pull_enabled    = false

  # No public pulls: the app reaches ACR over the VNet.
  public_network_access_enabled = false

  # Pull over a registry-dedicated endpoint rather than the shared *.blob domain,
  # so firewall rules can name the registry precisely.
  data_endpoint_enabled = true

  # The registry is the single supply-chain chokepoint for every deploy; losing an
  # AZ should not stop a rollback.
  zone_redundancy_enabled = true

  retention_policy_in_days = 30

  tags = local.tags
}
