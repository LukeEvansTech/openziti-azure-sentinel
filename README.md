# openziti-azure-sentinel

Ship [OpenZiti](https://openziti.io) events into Microsoft Sentinel using
OpenZiti v2.0's native Azure Service Bus event sink, an Azure Function, and the
Azure Monitor Logs Ingestion API. Terraform-provisioned, one command up, one
command down. Includes a Sentinel custom table, two scheduled analytics rules,
and a workbook.

## Architecture

![Data flow: OpenZiti controller to Service Bus to Azure Function to DCE/DCR to the OpenZitiEvents_CL table read by Sentinel analytics rules and a workbook](docs/assets/data-flow.png)

The controller emits its structured JSON events to a Service Bus queue over a
Send-only SAS rule. The Function is triggered by the queue (a Listen-only
connection string, because the Consumption scale controller cannot peek the queue
with a managed identity), and forwards each event to the Logs Ingestion API using
its system-assigned managed identity.

The DCR applies an ingestion-time KQL transform, so the Function stays a
schema-stable passthrough (`TimeGenerated` + `RawData`) and column projection
(`Namespace`, `EventType`, `IdentityId`, ...) lives in the DCR. Changing the
shape of the parsed columns is a DCR edit, not a code change and redeploy.

## Quickstart (self-contained demo)

The defaults stand up everything you need to see events flowing end-to-end: a
demo OpenZiti v2.0 controller on Azure Container Instances (with a sidecar that
generates real authentication events), the Service Bus queue, the Function, and a
brand-new Log Analytics workspace with Sentinel onboarded.

Prerequisites:

- Azure CLI, logged in (`az login`)
- Terraform >= 1.12
- Azure Functions Core Tools (`func`)
- Python 3.12

If you use [mise](https://mise.jdx.dev), `mise install` picks up the pinned tool
versions from `.mise.toml`; otherwise install the above yourself.

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

On Windows (or anywhere with PowerShell), every script has a PowerShell twin
with the same behaviour and retry logic - run `./scripts/deploy.ps1`,
`./scripts/verify.ps1`, and `./scripts/teardown.ps1` instead. Both Windows
PowerShell 5.1 and PowerShell 7+ work.

The Function forwards to the Logs Ingestion API using its managed identity, which
is granted **Monitoring Metrics Publisher** on the DCR. That role assignment can
take up to ~30 minutes to propagate: an initial `403` from the Function is
expected during that window, not a broken deployment. `deploy.sh` retries the
code publish for the same reason. Events keep buffering on the queue until the
Function can write, so nothing is lost.

To exercise the Azure half of the pipeline without a controller at all, push the
canonical sample events straight onto the queue:

```bash
pip install azure-servicebus                 # a venv is fine
python scripts/inject_sample_events.py       # one batch; pass a count to send more
```

### Demo security posture

The demo controller takes sensible defaults but is not hardened, and it faces
the internet:

- It gets a public ACI FQDN with port `1280` (the edge/management API) exposed to
  the internet. Retrieve the endpoint with
  `terraform output -raw controller_fqdn`.
- Its admin credential is a strong random password (not a default), marked
  sensitive in state. Retrieve it with
  `terraform output -raw controller_admin_password`.
- Its PKI is self-signed.

This is a demo, not a production controller - tear it down with
`./scripts/teardown.sh` when you are finished.

## Production shape

Two independent toggles turn the self-contained demo into a production
deployment.

### 1. Bring your own controller (`deploy_demo_controller = false`)

With the demo controller disabled, Terraform provisions only the ingestion side
(Service Bus, Function, DCE/DCR, table, rules, workbook). Point your existing
OpenZiti v2.0 controller's Service Bus event sink at the queue by adding this to
its config (the connection string comes from the `servicebus_send_connection_string`
Terraform output, and the queue is `openziti-events`):

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

The servicebus handler only takes a SAS connection string - it does not support
managed identity - so the Send-only rule's connection string goes into the
controller config directly.

### 2. Target an existing Sentinel workspace (`create_workspace = false`)

Set `create_workspace = false` and supply `workspace_resource_id` to write into
an existing central Sentinel workspace. Terraform never creates, modifies, or
destroys that workspace; it only adds the custom table, DCE, DCR, analytics
rules, and workbook.

- `retention_in_days` must be >= the target workspace's retention, or the
  custom table create fails.
- Deploying with Contributor alone fails on the DCR role assignment - it
  needs **User Access Administrator** or **Owner** on the scope.
- If the target workspace is not Sentinel-onboarded, set
  `enable_analytics_rules = false` (the scheduled rules require Sentinel).

## Variables

All variables live in `terraform/variables.tf`; see
`terraform/terraform.tfvars.example` for a worked configuration.

| Variable                          | Default      | Purpose                                                                                                                                                                                   |
| --------------------------------- | ------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `subscription_id`                 | _(required)_ | Target Azure subscription ID.                                                                                                                                                             |
| `location`                        | `uksouth`    | Azure region.                                                                                                                                                                             |
| `prefix`                          | `ozsent`     | Short dash-style name prefix for resources.                                                                                                                                               |
| `deploy_demo_controller`          | `true`       | Stand up a self-contained OpenZiti demo controller (plus an event-generator sidecar) on ACI, wired to the pipeline. Set `false` in production and point your own controller at the queue. |
| `create_workspace`                | `true`       | Create a Log Analytics workspace + Sentinel. Set `false` to target an existing central workspace via `workspace_resource_id`.                                                             |
| `workspace_resource_id`           | `""`         | Existing Log Analytics workspace resource ID, used when `create_workspace = false`.                                                                                                       |
| `enable_analytics_rules`          | `true`       | Deploy the two scheduled analytics rules. Requires the target workspace to be Sentinel-onboarded.                                                                                         |
| `retention_in_days`               | `30`         | Workspace/table retention (PerGB2018 floor is 30; must be >= the target workspace retention when reusing one).                                                                            |
| `resource_provider_registrations` | `extended`   | azurerm resource-provider registration mode. Use `none` on governed subscriptions with providers pre-registered.                                                                          |
| `budget_amount`                   | `20`         | Monthly resource-group budget amount, in your billing currency, for the alert. `0` disables the budget.                                                                                   |
| `budget_contact_email`            | `""`         | Email for the budget alert. Empty disables notifications.                                                                                                                                 |
| `budget_start_date`               | `""`         | Optional budget start date (first of a month). Empty derives the first of the current month.                                                                                              |
| `tags`                            | `{}`         | Extra tags merged over the defaults (`project`, `managedBy`).                                                                                                                             |

## Cost

In demo mode the running cost is dominated by the ACI controller group: roughly
1.25 vCPU / 2.5 GB running 24/7, on the order of GBP 1.50/day. On top of that:

- **Service Bus** Standard namespace.
- **Azure Function** on a Y1 Consumption plan - near-zero at demo event volume.
- **Log Analytics** ingestion for the events that land.

The resource-group budget alert is opt-in and does nothing unless you set
`budget_contact_email`. With it set, Terraform creates a monthly budget (default
`budget_amount` of 20 in your billing currency) with alerts at the 80% and 100%
thresholds. Without it, there is no automatic spend guardrail - the only backstops
are you tearing the deployment down or pausing the controller (below).

To pause spend without tearing down, `az container stop` the demo controller
group. The controller's identity survives restarts via an Azure Files snapshot
of its PKI and config, so it comes back up without re-minting certificates. When
you are done, `./scripts/teardown.sh` removes everything.

## Detections

Two scheduled analytics rules ship with the deployment: an authentication-failure
spike rule and a policy/service configuration-change rule.

A caveat when authoring your own detections: in OpenZiti v2.0.0, `Success` on
authentication events is not a reliable outcome flag - a `success` event with
`success` set to `false` has been observed. The shipped auth-failure rule keys on
`EventType in ("fail", "failed")` rather than the boolean. Key your own detections
on `EventType`, not `Success`.

## Troubleshooting

The problems hit while building this - DCR/RBAC propagation, the ACI/CIFS PKI
snapshot, retention conflicts, Sentinel rule-id cooldowns after teardown - are
written up in [`docs/troubleshooting.md`](docs/troubleshooting.md). A deeper
walkthrough of the pipeline is in [`docs/architecture.md`](docs/architecture.md).

## License

MIT. See [`LICENSE`](LICENSE).
