resource "azurerm_container_app_environment" "main" {
  name                       = "${local.name}-env"
  resource_group_name        = azurerm_resource_group.main.name
  location                   = azurerm_resource_group.main.location
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id
  infrastructure_subnet_id   = azurerm_subnet.apps.id

  # Keep egress inside the VNet so the private endpoint is actually used.
  internal_load_balancer_enabled = false

  tags = local.tags
}

resource "azurerm_container_app" "main" {
  name                         = "${local.name}-app"
  resource_group_name          = azurerm_resource_group.main.name
  container_app_environment_id = azurerm_container_app_environment.main.id
  revision_mode                = "Single"
  tags                         = local.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app.id]
  }

  # Pull with the managed identity — no registry username/password.
  registry {
    server   = azurerm_container_registry.main.login_server
    identity = azurerm_user_assigned_identity.app.id
  }

  ingress {
    external_enabled = true
    target_port      = var.container_port
    transport        = "auto"
    # Container Apps terminates TLS and redirects HTTP itself — there is no
    # listener/cert/redirect to wire up the way an ALB needs. See the comparison doc.
    allow_insecure_connections = false

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = var.min_replicas
    max_replicas = var.max_replicas

    container {
      name   = "app"
      image  = "${azurerm_container_registry.main.login_server}/${local.name}:${var.image_tag}"
      cpu    = 0.25
      memory = "0.5Gi"

      env {
        name  = "COSMOS_URL"
        value = azurerm_cosmosdb_account.main.endpoint
      }
      env {
        name  = "COSMOS_DB"
        value = azurerm_cosmosdb_sql_database.notes.name
      }
      env {
        name  = "COSMOS_CONTAINER"
        value = azurerm_cosmosdb_sql_container.notes.name
      }
      env {
        # DefaultAzureCredential has to be told WHICH user-assigned identity to
        # use — a container can carry several, and it will not guess.
        name  = "AZURE_CLIENT_ID"
        value = azurerm_user_assigned_identity.app.client_id
      }

      # Liveness must not depend on Cosmos; readiness must. Same split as AWS.
      liveness_probe {
        transport = "HTTP"
        port      = var.container_port
        path      = "/health"
      }

      readiness_probe {
        transport = "HTTP"
        port      = var.container_port
        path      = "/ready"
      }
    }

    # Scale on concurrent HTTP requests. The AWS side target-tracks CPU; Container
    # Apps' native trigger is request concurrency, which is the better signal for
    # an IO-bound API anyway.
    http_scale_rule {
      name                = "http-concurrency"
      concurrent_requests = 50
    }
  }

  depends_on = [
    azurerm_role_assignment.app_acr_pull,
    azurerm_cosmosdb_sql_role_assignment.app_data,
  ]
}
