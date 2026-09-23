output "app_url" {
  description = "Public HTTPS endpoint of the container app"
  value       = "https://${azurerm_container_app.main.ingress[0].fqdn}"
}

output "registry_login_server" {
  value = azurerm_container_registry.main.login_server
}

output "deploy_identity_client_id" {
  description = "Set as AZURE_CLIENT_ID in GitHub repo variables for keyless CI"
  value       = azurerm_user_assigned_identity.deploy.client_id
}

output "tenant_id" {
  value = data.azurerm_client_config.current.tenant_id
}

output "cosmos_endpoint" {
  value = azurerm_cosmosdb_account.main.endpoint
}
