# Deployment

Two shapes come out of the same Terraform: a self-contained demo that stands up everything
including a controller, and a production deployment that provisions only the ingestion side
and targets your own controller and Sentinel workspace.

## Quickstart (self-contained demo)

The defaults stand up everything needed to see events flowing end-to-end: a demo OpenZiti
v2.0 controller on Azure Container Instances (with a sidecar that generates real
authentication events), the Service Bus queue, the Function, and a brand-new Log Analytics
workspace with Sentinel onboarded.

Prerequisites:

- Azure CLI, logged in (`az login`)
- Terraform >= 1.12
- Azure Functions Core Tools (`func`)
- Python 3.12

If you use [mise](https://mise.jdx.dev), `mise install` picks up the pinned tool versions
from `.mise.toml`; otherwise install the above yourself.

```bash
# 1. Point Terraform at your subscription (and, optionally, a spend-alert email).
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Edit terraform/terraform.tfvars: set subscription_id
# (optionally set budget_contact_email to turn on the cost alert).

# 2. terraform apply, then publish the Function code.
./scripts/deploy.sh

# 3. Query OpenZitiEvents_CL and show event counts by namespace and type.
./scripts/verify.sh

# 4. Destroy everything and purge the soft-deleted workspace.
./scripts/teardown.sh
```

On Windows (or anywhere with PowerShell), every script has a PowerShell twin with the same
behaviour and retry logic - run `./scripts/deploy.ps1`, `./scripts/verify.ps1`, and
`./scripts/teardown.ps1` instead. Both Windows PowerShell 5.1 and PowerShell 7+ work.

!!! note "An initial 403 is expected"
    The Function forwards to the Logs Ingestion API using its managed identity, which is
    granted **Monitoring Metrics Publisher** on the DCR. That role assignment can take up to
    ~30 minutes to propagate: an initial `403` from the Function is expected during that
    window, not a broken deployment. `deploy.sh` retries the code publish for the same
    reason, and events keep buffering on the queue until the Function can write, so nothing
    is lost.

### Demo security posture

The demo controller takes sensible defaults but is not hardened, and it faces the internet:

- It gets a public ACI FQDN with port `1280` (the edge/management API) exposed to the
  internet. Retrieve it with `terraform output -raw controller_fqdn`.
- Its admin credential is a strong random password (not a default), marked sensitive in
  state. Retrieve it with `terraform output -raw controller_admin_password`.
- Its PKI is self-signed.

This is a demo, not a production controller - tear it down with `./scripts/teardown.sh` when
you are finished. The rationale for running the demo controller on ACI (rather than a VM) is
in [architecture.md](architecture.md#demo-controller-on-aci).

## Production shape

Two independent toggles turn the demo into a production deployment.

### 1. Bring your own controller (`deploy_demo_controller = false`)

With the demo controller disabled, Terraform provisions only the ingestion side (Service
Bus, Function, DCE/DCR, table, rules, workbook). Point your existing OpenZiti v2.0
controller's Service Bus event sink at the queue by adding this to its config (the
connection string comes from the `servicebus_send_connection_string` Terraform output, and
the queue is `openziti-events`):

```yaml
events:
  serviceBusLogger:
    subscriptions:
      - type: authentication
      - type: apiSession
      - type: session
      - type: circuit
      - type: entityChange
    handler:
      type: servicebus
      format: json
      connectionString: "<servicebus_send_connection_string output>"
      queue: openziti-events
      bufferSize: 100
```

The `servicebus` handler only takes a SAS connection string - it does not support managed
identity - so the Send-only rule's connection string goes into the controller config
directly.

### 2. Target an existing Sentinel workspace (`create_workspace = false`)

Set `create_workspace = false` and supply `workspace_resource_id` to write into an existing
central Sentinel workspace. Terraform never creates, modifies, or destroys that workspace; it
only adds the custom table, DCE, DCR, analytics rules, and workbook.

- `retention_in_days` must be >= the target workspace's retention, or the custom table
  create fails.
- Deploying with Contributor alone fails on the DCR role assignment - it needs **User
  Access Administrator** or **Owner** on the scope.
- If the target workspace is not Sentinel-onboarded, set `enable_analytics_rules = false`
  (the scheduled rules require Sentinel).

## Variables

All variables live in `terraform/variables.tf`; see `terraform/terraform.tfvars.example` for
a worked configuration.

| Variable | Default | Purpose |
| --- | --- | --- |
| `subscription_id` | _(required)_ | Target Azure subscription ID. |
| `location` | `uksouth` | Azure region. |
| `prefix` | `ozsent` | Short dash-style name prefix for resources. |
| `deploy_demo_controller` | `true` | Stand up a self-contained OpenZiti demo controller (plus an event-generator sidecar) on ACI, wired to the pipeline. Set `false` in production and point your own controller at the queue. |
| `create_workspace` | `true` | Create a Log Analytics workspace + Sentinel. Set `false` to target an existing central workspace via `workspace_resource_id`. |
| `workspace_resource_id` | `""` | Existing Log Analytics workspace resource ID, used when `create_workspace = false`. |
| `enable_analytics_rules` | `true` | Deploy the two scheduled analytics rules. Requires the target workspace to be Sentinel-onboarded. |
| `retention_in_days` | `30` | Workspace/table retention (PerGB2018 floor is 30; must be >= the target workspace retention when reusing one). |
| `resource_provider_registrations` | `extended` | azurerm resource-provider registration mode. Use `none` on governed subscriptions with providers pre-registered. |
| `budget_amount` | `20` | Monthly resource-group budget amount, in your billing currency, for the alert. `0` disables the budget. |
| `budget_contact_email` | `""` | Email for the budget alert. Empty disables notifications. |
| `budget_start_date` | `""` | Optional budget start date (first of a month). Empty derives the first of the current month. |
| `tags` | `{}` | Extra tags merged over the defaults (`project`, `managedBy`). |

*[DCR]: Data Collection Rule
*[DCE]: Data Collection Endpoint
*[SAS]: Shared Access Signature
*[KQL]: Kusto Query Language
*[ACI]: Azure Container Instances
