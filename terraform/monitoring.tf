resource "azurerm_log_analytics_workspace" "main" {
  name                = "${local.name}-law"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}

resource "azurerm_monitor_action_group" "main" {
  count               = var.alert_email == "" ? 0 : 1
  name                = "${local.name}-ag"
  resource_group_name = azurerm_resource_group.main.name
  short_name          = "acpalerts"

  email_receiver {
    name          = "oncall"
    email_address = var.alert_email
  }

  tags = local.tags
}

# Availability: the app's own replica count dropping to zero while it is supposed
# to be serving. Mirrors the AWS side's ECS running-task-count alarm.
resource "azurerm_monitor_metric_alert" "replicas_zero" {
  count               = var.alert_email == "" ? 0 : 1
  name                = "${local.name}-no-replicas"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_container_app.main.id]
  description         = "The container app has no running replicas."
  severity            = 1
  frequency           = "PT1M"
  window_size         = "PT5M"

  criteria {
    metric_namespace = "Microsoft.App/containerApps"
    metric_name      = "Replicas"
    aggregation      = "Average"
    operator         = "LessThan"
    threshold        = 1
  }

  action {
    action_group_id = azurerm_monitor_action_group.main[0].id
  }

  tags = local.tags
}

resource "azurerm_monitor_diagnostic_setting" "cosmos" {
  name                       = "${local.name}-cosmos-diag"
  target_resource_id         = azurerm_cosmosdb_account.main.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log {
    category = "DataPlaneRequests"
  }

  enabled_metric {
    category = "Requests"
  }
}
