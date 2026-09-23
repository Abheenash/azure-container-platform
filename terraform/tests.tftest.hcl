# Native terraform tests (`terraform test`) against a mocked provider — no Azure
# subscription, no cost. These assert the promises this repo's README makes,
# particularly the "no key, no connection string, no secret anywhere" claim,
# which is the whole identity story and deserves a test rather than a sentence.

mock_provider "azurerm" {}
mock_provider "random" {}

variables {
  subscription_id = "00000000-0000-0000-0000-000000000000"
}

run "cosmos_has_keys_disabled_and_no_public_path" {
  command = plan

  # checkov CANNOT see this: CKV_AZURE_140 still reads the pre-v5 attribute name
  # `local_authentication_disabled`, so it reports a false positive here (see
  # .checkov.yaml). This test asserts the control the scanner cannot.
  assert {
    condition     = !azurerm_cosmosdb_account.main.local_authentication_enabled
    error_message = "Cosmos key auth must stay disabled — the app authenticates with its managed identity. A connection string cannot leak if one never exists."
  }

  assert {
    condition     = !azurerm_cosmosdb_account.main.public_network_access_enabled
    error_message = "Cosmos must only be reachable over the private endpoint."
  }

  assert {
    condition     = !azurerm_cosmosdb_account.main.access_key_metadata_writes_enabled
    error_message = "Key metadata writes must be blocked, so nobody can regenerate a key and quietly restore a credential path."
  }
}

run "registry_has_no_admin_user_and_no_public_pulls" {
  command = plan

  assert {
    condition     = !azurerm_container_registry.main.admin_enabled
    error_message = "ACR's admin account is a username/password pair. Pulls use the managed identity instead."
  }

  assert {
    condition     = !azurerm_container_registry.main.anonymous_pull_enabled
    error_message = "Anonymous pull must stay off."
  }
}

run "container_app_declares_both_probes" {
  command = plan

  # The same invariant as the custom policy CKV_ACP_1, asserted from the other
  # direction. It exists because of a measured EKS drill finding: liveness and
  # readiness sharing an endpoint killed busy pods instead of draining them.
  assert {
    condition = alltrue([
      for c in azurerm_container_app.main.template[0].container :
      length(c.liveness_probe) > 0 && length(c.readiness_probe) > 0
    ])
    error_message = "Every container must declare both a liveness and a readiness probe. They answer different questions and must not share an endpoint."
  }
}

run "ingress_refuses_plaintext" {
  command = plan

  assert {
    condition     = !azurerm_container_app.main.ingress[0].allow_insecure_connections
    error_message = "Container Apps terminates TLS and redirects HTTP itself; allowing insecure connections would throw that away."
  }
}

run "ci_federation_is_pinned_to_this_repo" {
  command = plan

  # A federated credential whose subject is too broad lets any repo — or any
  # fork's pull request — mint a token for the deploy identity.
  assert {
    condition     = azurerm_federated_identity_credential.github_main.subject == "repo:${var.github_repo}:ref:refs/heads/main"
    error_message = "The main-branch federated credential must pin both the repo and the ref."
  }

  assert {
    condition     = azurerm_federated_identity_credential.github_pr.subject == "repo:${var.github_repo}:pull_request"
    error_message = "Pull requests must use a separate subject so a fork's PR cannot assume the main-branch identity."
  }
}
