# Azure Container Platform — the same service as my AWS one, built again on Azure

> **Sep 2026:** first release — Container Apps + Cosmos DB (serverless) + ACR, managed identity end to end (no keys, no connection strings), keyless CI via workload identity federation, 13 checkov checks and 15 tests green, `terraform validate` clean. Deliberately not applied.

A deliberate port of [`secure-container-pipeline`](https://github.com/Abheenash/secure-container-pipeline)
— the **same notes API, same routes, same probes, same log shape** — rebuilt on
**Azure Container Apps, Cosmos DB and ACR**, so the two can be diffed against each
other.

**The deliverable is the diff, not the app.** Anyone can follow a quickstart. What
a second cloud actually shows is which of your decisions were engineering and
which were just AWS vocabulary. That write-up is
[**docs/aws-vs-azure.md**](docs/aws-vs-azure.md) and it is the thing worth reading.

**Status:** `terraform validate` clean against azurerm 5.x, checkov clean against a
reviewed baseline, 15 unit tests green. **Not applied** — a Container Apps
environment plus a Premium ACR is real monthly spend for a demo, and the AWS
original already carries the "applied and proven" evidence.

## Why this exists

Every cloud project I had was AWS. Reading 853 job requisitions across nineteen
employers for my own search, **Azure appeared 172 times and Kubernetes 77** — the
enterprises I was targeting are hybrid by default, and a portfolio that only
speaks one cloud reads as someone who learned a platform rather than the domain.

So this is not "an Azure tutorial project". It is the same problem, solved twice,
with the differences written down.

## Architecture

```
GitHub Actions ──(OIDC, federated credential — no secret)──► Azure
     │
     ├─ build ─► ACR (Premium, no admin user, quarantine, private)
     │             │
     │             │ pull via managed identity (AcrPull)
     ▼             ▼
  cosign + SLSA   Container App ──► Cosmos DB for NoSQL (serverless)
  attestation      (min 1 / max 4)      ▲
                   managed identity ────┘  data-plane RBAC, keys disabled
                        │
                        └─► Log Analytics workspace
```

Everything reachable only over the VNet: the Container Apps environment is
injected into a delegated subnet, and Cosmos is a private endpoint with a linked
private DNS zone. There is no key, no connection string and no client secret
anywhere in this repo or in the deployed config.

## The pipeline

Same four gates as the AWS side, in the same order:

| Gate | What blocks the build |
| --- | --- |
| **gitleaks** | any secret in the diff or history |
| **checkov** | any IaC finding outside the reviewed `.checkov.yaml` baseline, plus `terraform fmt -check` and `validate` |
| **pytest** | 15 tests: liveness-without-backend, readiness-503, CRUD, 404s, validation bounds, pagination caps, security headers, drill flag, docs disabled |
| **trivy** | HIGH/CRITICAL CVEs (fixed only), secrets in image layers, and a non-root assertion (`uid 10001`) — plus a CycloneDX SBOM artifact |

On `main` with `DEPLOY_ENABLED=true`: federated login → ACR push → cosign signature
→ **SLSA build provenance attestation** → `az containerapp update`.

`trivy` is pinned to **v0.69.3** and its install script fetched at that tag — not
`@main`. Trivy's supply chain was compromised twice in March 2026
([CVE-2026-33634](https://github.com/advisories/GHSA-69fq-xp46-6x23)); v0.69.4–.6
were malicious and mutable refs were the delivery path.

## Running it

```bash
cd terraform
terraform init
terraform apply -var subscription_id=<your-sub-id>

# tests need no Azure account at all
pip install -r tests/requirements.txt -r app/requirements.txt
python -m pytest tests -q
```

Then set the repo variables the deploy job reads: `AZURE_CLIENT_ID` (the
`deploy_identity_client_id` output), `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`,
`ACR_LOGIN_SERVER`, `CONTAINER_APP_NAME`, `RESOURCE_GROUP`, and `DEPLOY_ENABLED=true`.

## Cost, honestly

Container Apps bills per vCPU-second with a monthly free grant; Cosmos serverless
bills per request unit; **Premium ACR is ~$50/month and is the real cost here** —
it is required for private access and zone redundancy. Destroy between demos. A
Basic ACR drops the bill to ~$5 and loses the private-network story, which is why
the config uses Premium and says so rather than quietly downgrading.

## Layout

```
app/          the ported FastAPI service (Cosmos instead of DynamoDB)
terraform/    resource group, VNet + delegated subnet, private endpoint + DNS,
              ACR, Cosmos, both managed identities + federated credentials,
              Container App, Log Analytics, alerts
tests/        15 tests against an in-memory fake Cosmos container (no Azure needed)
docs/         the cross-cloud comparison — the point of the repo
.github/      the four-gate pipeline + keyless deploy
```

## Not affiliated with Microsoft — a personal learning + portfolio project by
[Rajolu Abheenash](https://abheenash.com).
