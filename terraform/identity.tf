# Two identities, deliberately separate — the same split as the AWS side's
# task role vs. GitHub Actions deploy role.
#
#   app     — what the running container is, at runtime. Pulls from ACR, reads and
#             writes its own Cosmos container, and nothing else.
#   deploy  — what CI is. Pushes images and updates the app. Never touches data.

resource "azurerm_user_assigned_identity" "app" {
  name                = "${local.name}-app-id"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = local.tags
}

resource "azurerm_user_assigned_identity" "deploy" {
  name                = "${local.name}-deploy-id"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = local.tags
}

# --- runtime permissions -----------------------------------------------------

resource "azurerm_role_assignment" "app_acr_pull" {
  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
}

# Cosmos data-plane access is NOT an Azure RBAC role — it is a separate role
# system scoped to the account. Granting "Contributor" on the account would let
# you manage it and still not read a single document. This is the Azure
# equivalent of a DynamoDB resource policy, and it is the single most common
# thing people get wrong when porting from AWS.
data "azurerm_cosmosdb_sql_role_definition" "data_contributor" {
  resource_group_name = azurerm_resource_group.main.name
  account_name        = azurerm_cosmosdb_account.main.name
  role_definition_id  = "00000000-0000-0000-0000-000000000002" # built-in Data Contributor
}

resource "azurerm_cosmosdb_sql_role_assignment" "app_data" {
  resource_group_name = azurerm_resource_group.main.name
  account_name        = azurerm_cosmosdb_account.main.name
  role_definition_id  = data.azurerm_cosmosdb_sql_role_definition.data_contributor.id
  principal_id        = azurerm_user_assigned_identity.app.principal_id
  # Scoped to this account's data, not the subscription.
  scope = azurerm_cosmosdb_account.main.id
}

# --- CI permissions ----------------------------------------------------------

resource "azurerm_role_assignment" "deploy_acr_push" {
  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPush"
  principal_id         = azurerm_user_assigned_identity.deploy.principal_id
}

resource "azurerm_role_assignment" "deploy_app_contributor" {
  scope                = azurerm_resource_group.main.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.deploy.principal_id
}

# Workload identity federation: GitHub's OIDC token is exchanged for an Azure
# token, so CI holds no client secret. Exactly the same idea as the AWS side's
# OIDC trust policy — the subject claim is what pins it to this repo's main branch.
resource "azurerm_federated_identity_credential" "github_main" {
  name                      = "github-main"
  user_assigned_identity_id = azurerm_user_assigned_identity.deploy.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = "https://token.actions.githubusercontent.com"
  subject                   = "repo:${var.github_repo}:ref:refs/heads/main"
}

# Pull requests get their own credential so a fork's PR cannot assume the
# deploy identity — the subject claim differs.
resource "azurerm_federated_identity_credential" "github_pr" {
  name                      = "github-pr"
  user_assigned_identity_id = azurerm_user_assigned_identity.deploy.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = "https://token.actions.githubusercontent.com"
  subject                   = "repo:${var.github_repo}:pull_request"
}
