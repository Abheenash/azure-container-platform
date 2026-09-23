# The same service, built twice

Both repos run an identical FastAPI notes API — same routes, same status codes,
same JSON log line, same security headers, same `/health` vs `/ready` split. The
app code differs only in its data-access calls. Everything else that changed is
the cloud, which is what makes the diff worth reading.

| | AWS (`secure-container-pipeline`) | Azure (this repo) |
|---|---|---|
| Compute | ECS Fargate service | Container Apps |
| Ingress | ALB + listener + target group + ACM cert + HTTP→HTTPS redirect rule | Container Apps ingress (one block) |
| Data | DynamoDB, on-demand | Cosmos DB for NoSQL, serverless |
| Registry | ECR | ACR (Premium) |
| Runtime identity | IAM task role | User-assigned managed identity |
| CI identity | IAM role + OIDC trust policy | Managed identity + federated credential |
| Private data path | VPC interface endpoints | Private endpoint + private DNS zone |
| Logs | CloudWatch Logs | Log Analytics workspace |
| Secrets | Secrets Manager | (not needed — no credential exists) |
| Autoscaling signal | CPU target tracking | HTTP concurrent requests |

## Five things that are genuinely different

### 1. Cosmos data-plane RBAC is a separate permission system

This is the one that bites people porting from AWS. On AWS, `dynamodb:GetItem`
is an IAM action like any other. On Azure, granting **Contributor on the Cosmos
account** lets you delete the account and still not read one document. Data
access is a *different* role system, scoped to the account, assigned with
`azurerm_cosmosdb_sql_role_assignment` against a role definition id like
`00000000-0000-0000-0000-000000000002`.

The mental model that works: Azure RBAC governs the *resource*, Cosmos RBAC
governs the *contents*. Nothing in AWS has this split.

### 2. `DefaultAzureCredential` will not guess which identity to use

An AWS task assumes exactly one task role, so `boto3` needs no hint. An Azure
container can carry several user-assigned identities at once, so the SDK refuses
to pick — you must pass `AZURE_CLIENT_ID`. Omit it and you get a confusing
auth failure at runtime that looks like a permissions problem and isn't.

### 3. Ingress is one block instead of five resources

The AWS side needs `aws_lb`, `aws_lb_target_group`, `aws_lb_listener`, a second
listener for the HTTP→HTTPS 301, and an ACM certificate. Container Apps
terminates TLS, provisions the certificate, and redirects HTTP itself. That is
genuinely less to get wrong — and genuinely less control: there is no WAF in
front of it without putting Front Door or Application Gateway in the path, which
is a whole extra tier. The AWS side has a WAF web ACL in ten lines.

### 4. Azure names are globally unique, and Terraform will not warn you

`aws_s3_bucket` names are global too, but ACR and Cosmos account names are
global *and* heavily length- and charset-restricted. A `random_string` suffix is
not decoration here; without it a second person applying this config fails forty
resources in. The `name_prefix` variable carries a regex validation for the same
reason — failing at plan time beats failing at apply time.

### 5. ACR has no working "refuse unsigned images" control

ECR's story is thin too, but Azure went backwards: content trust is being
retired and `trust_policy_enabled` was **removed from the azurerm provider in
v5.0**. There is no native replacement. So on this side, provenance is entirely
the pipeline's job — cosign signature plus SLSA attestation, with ACR's
quarantine policy covering only the CVE half. Checkov still flags `CKV_AZURE_164`
for a control the provider can no longer express; that is baselined in
`.checkov.yaml` with this reasoning.

## A false positive worth knowing about

`CKV_AZURE_140` ("Local Authentication is disabled on CosmosDB") fails against
this config even though local auth **is** disabled. Checkov 3.3.10 reads the
attribute `local_authentication_disabled`; azurerm v5.0 renamed it to
`local_authentication_enabled`. Verified in the installed source at
`checkov/terraform/checks/resource/azure/CosmosDBLocalAuthDisabled.py`.

The point of writing that down: a scanner finding is evidence, not a verdict. The
right response was to read the check, prove it was stale, and record why — not to
add a property that no longer exists so the tool goes quiet.

## What was the same

Almost all of the thinking. Least privilege, keyless CI, liveness-vs-readiness,
private data paths, pinned dependencies, a reviewed scanner baseline with written
reasons, scan gates that block the build. The vocabulary changed completely and
the engineering did not — which is the actual argument for hiring someone who has
only shipped on one cloud.
