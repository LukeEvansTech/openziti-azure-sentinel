# Troubleshooting

Field-tested findings from building and running this pipeline, grouped by area.
Each entry is a symptom, its cause, and the fix.

For the full data flow and design rationale, see
[architecture.md](architecture.md).

## Ingestion path

- **First Function run returns `403` from the Logs Ingestion API.**
  - Cause: the Function's managed identity was just granted **Monitoring Metrics
    Publisher** on the Data Collection Rule (DCR), and that role assignment can
    take ~30 minutes to propagate.
  - Fix: expected on a cold deploy, not a defect. Events buffer on the queue
    until the Function can write, and `deploy.sh` retries the code publish. Wait
    out the propagation window.

- **Uploads fail with HTTP `404`.**
  - Cause: a wrong DCR immutable ID, or a stream-name mismatch. The stream must be
    `Custom-OpenZitiEvents_CL` in the DCR `stream_declaration`, the DCR
    `output_stream`, **and** the Function's upload call.
  - Fix: make all three identical, and confirm the Function is reading the DCR
    immutable ID (not the DCR resource ID) from its app settings.

- **Events go missing under bursty load.**
  - Cause: the OpenZiti `servicebus` sink does a non-blocking send and drops
    events when its `bufferSize` fills. Watch for the `service bus queue full` log
    line on the controller.
  - Fix: raise `bufferSize` in the sink config for bursty runs.

- **Controller reconnects endlessly and no messages arrive.**
  - Cause: a bad SAS key or wrong queue name. The sink treats `401`/`403`/`404`
    as connection errors and enters an infinite reconnect loop rather than failing
    fast, so the symptom is reconnect churn with no throughput.
  - Fix: validate the Send connection string and the queue name first; they are
    the usual culprits.

- **The `servicebus` handler config fields are undocumented.**
  - Cause: the OpenZiti config reference does not yet document the `servicebus`
    handler.
  - Fix: the field names (`connectionString`, `queue`, `bufferSize`, `format`)
    are verified from the v2.0.0 source (`controller/events/servicebus_logger.go`)
    and the packaged example config.

- **The DCR transform rejects `coalesce()`.**
  - Cause: the ingestion-time `transformKql` runs a restricted KQL subset that has
    no `coalesce()` (`Runtime scalar function provider not found for function:
coalesce`).
  - Fix: use `iif(isnotempty(tostring(x)), tostring(x), tostring(y))`. This is
    needed to reconcile OpenZiti's `event_type` (snake_case) vs `eventType`
    (camelCase, on `entityChange`) split.

- **The DCR create races the custom table.**
  - Cause: the DCR validates its `outputStream` against the `_CL` table at create
    time, and the analytics rules also need the table to exist.
  - Fix: keep the DCR's `depends_on` on the table, and expect a short
    queryable-lag after the table is created - the deploy retry loop covers it.

## Targeting an existing workspace

- **Custom table create fails with `400 InvalidParameter` on retention.**
  - Cause: the table's `totalRetentionInDays` must be **>=** the target
    workspace's retention. Pointing at a workspace with, say, 90-day retention
    while the table is set to 30 fails. A self-created workspace never hits this
    because it is created at the same retention.
  - Fix: set `retention_in_days` to match or exceed the target workspace. Note
    that `az ... table create --retention-time` sets only _interactive_ retention
    and can mask the problem; the `azapi` body sets total retention explicitly.

- **Analytics rules fail: `One of the tables does not exist`.**
  - Cause: the rules reference `OpenZitiEvents_CL` only inside a KQL string, so
    Terraform schedules them in parallel with the table, and Sentinel validates
    the query at create time before the table is ready.
  - Fix: the rules `depends_on` the table (in addition to onboarding). Keep that
    dependency.

- **DCR role assignment fails with Contributor.**
  - Cause: creating the role assignment needs
    `Microsoft.Authorization/roleAssignments/write`, which Contributor excludes.
  - Fix: grant **User Access Administrator** or **Owner** on the scope alongside
    Contributor. Everything else (table, DCR, Function, controller) is covered by
    Contributor.

- **Pre-flight checklist before deploying into a governed subscription.** Not a
  failure entry - a preventive checklist worth running before the first deploy
  into a governed subscription:
  - Resolve the workspace ARM ID from its customerId GUID:
    `az monitor log-analytics workspace list --query "[?customerId=='<guid>']"`.
  - Confirm resource-provider registration.
  - Scan `az policy assignment list` for deny-public-endpoint / force-private
    policies that would block public Data Collection Endpoint (DCE) ingestion or
    the demo controller.
  - Smoke-test container capacity live - it is not a queryable quota. Create a
    throwaway 1 vCPU / 2 GB container with `az container create`, confirm it
    reaches `Running`, then delete it.

## Function hosting

- **Flex Consumption deploys and publishes but never runs.**
  - Cause: on Flex Consumption the host published cleanly yet never executed the
    worker - zero Application Insights telemetry, and the queue never drained.
  - Fix: use a **Y1 Consumption** plan, which consumes the queue immediately.

- **Service Bus trigger never fires with a managed-identity connection.**
  - Cause: the Consumption scale controller cannot peek the queue over managed
    identity to scale from zero, so messages sit unconsumed.
  - Fix: use a **Listen** SAS connection string for the trigger. The Logs
    Ingestion upload still uses managed identity.

- **The Function host fails to initialise.**
  - Cause: `AzureWebJobsStorage` is a keyed connection string; a keyless storage
    account leaves the host unable to start.
  - Fix: set `shared_access_key_enabled = true` on the Functions runtime storage
    account.

## Azure Container Instances (ACI) demo controller

- **PKI bootstrap fails on the Azure Files mount.**
  - Cause: ziti's PKI store hard-links the intermediate CA bundle (`os.Link`),
    which CIFS does not support, and bbolt/raft uses mmap, which is unsafe over
    CIFS. Bootstrapping directly on the share wedges half-way.
  - Fix: bootstrap on container-local disk and snapshot only the identity
    (PKI + config) to the share; restore the snapshot on restart. The raft
    database is rebuilt on each start (`clusterInit` is idempotent).

- **The identity snapshot itself wedges bootstrap.**
  - Cause: `cp -a` implies `--preserve=links` and tries to recreate the PKI hard
    links on the share, dying part-way - after `config.yml` is already copied.
  - Fix: snapshot with `cp -rL` (never `cp -a`) and copy `config.yml` last, as the
    restore-branch sentinel. Any partial state on the share wedges bootstrap
    permanently; if in doubt, wipe the share and let it re-bootstrap.

- **The container dies immediately with empty logs.**
  - Cause: the image's `bootstrap()` writes DEBUG lines to fd 3, which the stock
    entrypoint opens but a bare `bash -c` script does not; under `set -e` the first
    DEBUG line kills the container.
  - Fix: the wrapper script must `exec 3>&1`.

- **`makePki` hard-errors on unset cluster variables.**
  - Cause: the image ENV does not set the cluster vars; `makePki` dereferences
    `ZITI_BOOTSTRAP_CLUSTER` under nounset and hard-fails on an empty trust domain.
  - Fix: set `ZITI_BOOTSTRAP_CLUSTER`, `ZITI_CLUSTER_TRUST_DOMAIN`, and
    `ZITI_CLUSTER_NODE_NAME` explicitly in the container environment.

- **`az container logs` returns mostly `None` for a crash-looping container.**
  - Cause: the log window between restarts is only seconds.
  - Fix: poll tightly and keep the longest snapshot; read
    `instanceView.events` and `previousState.exitCode` for the exit history.

- **Periodic `handshake failed` noise from `10.92.0.x` on port 1280.**
  - Cause: ACI infrastructure probes open TCP but never complete TLS.
  - Fix: none needed - this is expected noise, not a defect.

- **The controller keeps billing when idle.**
  - Cause: there is no auto-shutdown for ACI (the VM shutdown schedule is
    VM-only), so the group runs continuously.
  - Fix: `az container stop` when idle; the identity survives via the Azure Files
    snapshot, so it comes back up without re-minting its PKI.

## Lifecycle

- **Redeploying a Sentinel rule fails with `409` "recently deleted".**
  - Cause: `azurerm_sentinel_alert_rule_scheduled` uses the rule name as its ID,
    and a deleted ID stays reserved through a cooldown longer than a few minutes.
  - Fix: this repository suffixes rule names with the per-deploy random suffix, so
    redeploys always use fresh IDs and never collide.

- **Same-subscription redeploy of the Function fails with `401` quota.**
  - Cause: a just-deleted Y1 Consumption plan's quota is not released immediately;
    the limit briefly reads 0 (reported anywhere from ~30 min to hours). This is a
    subscription capacity limit, not code and not policy. A different subscription
    is unaffected.
  - Fix: wait for the quota to recover, or redeploy into a fresh subscription. The
    deploy retry loop deliberately does not wait this out (it would block for an
    unbounded time).

- **Budget create fails on `start_date`.**
  - Cause: a monthly budget's `start_date` must be the first of a month and not
    far in the past.
  - Fix: it is derived to the first of the current month via
    `formatdate(timestamp())`; do not hardcode a past date.

- **A soft-deleted workspace lingers after teardown.**
  - Cause: Log Analytics workspaces soft-delete for 14 days. The provider sets
    `permanently_delete_on_destroy`, but that only runs on the clean
    `terraform destroy` path.
  - Fix: teardown also purges any stray soft-deleted workspace of the same name.
    A leftover from a failed destroy is harmless and auto-purges in 14 days.

- **`terraform destroy` fails on the storage share, orphaning the workspace.**
  - Cause: `azurerm_storage_share` destroy goes through the storage **data plane**
    (token audience `storage.azure.com`), which can fail even when ARM auth is
    fine (`does not exist in MSAL token cache`), failing the whole destroy. The
    fallback `az group delete` then leaves the workspace soft-deleted.
  - Fix: the provider sets `storage_use_azuread = true`. If the fallback path
    still orphans a soft-deleted workspace, it is harmless and auto-purges in
    14 days.

- **`az monitor log-analytics query -w` returns nothing / errors on the ID.**
  - Cause: the query API wants the workspace **customerId** GUID, not the ARM
    resource ID.
  - Fix: resolve it first
    (`az monitor log-analytics workspace show --ids <arm-id> --query customerId`);
    `verify.sh` already does this.

## Event semantics

- **Authentication `Success` disagrees with `event_type`.**
  - Cause: in OpenZiti v2.0.0, an authentication event can carry
    `event_type: "success"` with `success: false` - observed consistently, with
    every event in a run reporting `success: false` regardless of `event_type`.
  - Fix: key detections on `EventType`, not `Success`. The shipped auth-failure
    rule keys on `EventType in ("fail", "failed")`.

## Subscriptions and providers

- **Small VM SKUs are unavailable (`NotAvailableForSubscription`).**
  - Cause: some subscription offers restrict small VM SKUs entirely (restriction
    type Location) even with healthy vCPU quota. This is a platform
    SKU-enablement matter tied to the offer, not an Azure Policy.
  - Fix: resolve it with a SKU/quota support request or a VM-capable subscription
    - or run the demo controller on ACI, which is why this repository does.

- **First apply fails with `MissingSubscriptionRegistration`.**
  - Cause: with `resource_provider_registrations = "none"` on a governed
    subscription, the required providers are not registered.
  - Fix: pre-register them, **sequentially** (a parallel loop can silently
    no-op): `Microsoft.Network`, `Microsoft.Storage`, `Microsoft.ServiceBus`,
    `Microsoft.OperationalInsights`, `Microsoft.Insights`,
    `Microsoft.SecurityInsights`, `Microsoft.OperationsManagement`,
    `Microsoft.Web`, `Microsoft.ContainerInstance`, and `Microsoft.Consumption`.
    `Microsoft.Consumption` is absent from every `azurerm` registration preset and
    is needed only for the optional budget alert.
