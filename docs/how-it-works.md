# How it works

This page follows one OpenZiti event from the moment the controller emits it to the moment
a Sentinel analytics rule can query it. Five stages, each a separate component.

## 1. The controller emits an event

OpenZiti's controller has an events subsystem that produces a structured JSON stream:
`authentication`, `apiSession`, `session`, `circuit`, `entityChange`, and more. From v2.0
the controller ships a native **`servicebus`** event sink, so it can push those events
straight into an Azure Service Bus queue with no host log agent.

The sink is configured in the controller's `config.yml`. This deployment subscribes to five
event types and points the handler at the queue:

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

The `servicebus` handler only takes a SAS connection string - there is no managed-identity
path in the shipped code - so a Send-only authorisation rule's connection string goes
into the config directly. Send-only is the whole point: the controller can enqueue events
but cannot read or manage the queue.

## 2. The queue buffers

The events land in an **Azure Service Bus Standard** queue named `openziti-events`. Standard
tier is enough here: the queue only needs plain queueing and durable buffering, not the
Premium features.

Buffering is what makes the queue more than a pipe. If the downstream Function is briefly
unavailable - for example while a fresh role assignment is still propagating - events wait
in the queue instead of being lost. The one limit to know about is backpressure at the
source: the sink does a non-blocking send and drops events once its `bufferSize` fills,
logging `service bus queue full`. Raise `bufferSize` for bursty runs (see
[troubleshooting](troubleshooting.md#ingestion-path)).

## 3. The Function forwards

An **Azure Function** (Python, Y1 Consumption) is triggered by the queue. Its trigger uses a
Listen connection string, not managed identity: the Consumption scale controller cannot
peek the queue over a managed identity to scale from zero, so a connection string is
required for the trigger to fire at all.

The Function itself is deliberately trivial and schema-stable. All it does is pull the
event timestamp into `TimeGenerated` and drop the whole event object into a `RawData`
column - the entire shaping step is these few lines:

```python
def shape(event: dict) -> dict:
    """Map an OpenZiti event to the DCR stream schema: TimeGenerated + RawData."""
    ts = event.get("timestamp") or datetime.now(timezone.utc).isoformat()
    return {"TimeGenerated": ts, "RawData": event}
```

It then uploads the shaped record to the Azure Monitor **Logs Ingestion API**:

```python
_logs_client.upload(rule_id=_DCR_ID, stream_name=_STREAM, logs=[record])
```

That upload authenticates with the Function's **system-assigned managed identity**, which
holds **Monitoring Metrics Publisher** on the Data Collection Rule (DCR). (Only the trigger
uses a connection string; the upload uses managed identity.)

## 4. The DCR transforms

The record reaches the DCR through the Data Collection Endpoint, and an **ingestion-time KQL
transform** does all the column projection before the row is written:

```kql
source
| extend TimeGenerated = todatetime(RawData.timestamp)
| extend Namespace  = tostring(RawData.namespace)
| extend EventType  = iif(isnotempty(tostring(RawData.event_type)),
                          tostring(RawData.event_type),
                          tostring(RawData.eventType))
| extend EventSrcId = tostring(RawData.event_src_id)
| extend IdentityId = tostring(RawData.identity_id)
| extend ServiceId  = tostring(RawData.service_id)
| extend EntityType = tostring(RawData.entityType)
| extend Success    = tobool(RawData.success)
| project TimeGenerated, Namespace, EventType, EventSrcId, IdentityId, ServiceId, EntityType, Success, RawData
```

(reflowed for readability; semantically identical to the transform in terraform/monitor.tf)

Keeping projection in the DCR rather than in the Function means the Function never has to
change when the parsed schema does: adding or renaming a column is a DCR edit, no code change
and no redeploy.

Two details in that KQL are load-bearing:

- **`iif(...)` instead of `coalesce()`.** The ingestion-time KQL runs a restricted subset
  that has no `coalesce()`, so the fallback is written out as
  `iif(isnotempty(tostring(x)), tostring(x), tostring(y))`.
- **snake_case vs camelCase.** Most namespaces expose `event_type` (snake_case), but
  `entityChange` uses `eventType` (camelCase). The `iif` reconciles the two into a single
  `EventType` column.

## 5. Sentinel consumes

The row lands in the **`OpenZitiEvents_CL`** custom table, with these columns:
`TimeGenerated`, `Namespace`, `EventType`, `EventSrcId`, `IdentityId`, `ServiceId`,
`EntityType`, `Success`, and the full `RawData` dynamic object.

Two scheduled analytics rules and a workbook read from that table:

- **Authentication-failure spike** - flags an identity with more than five failed
  authentications in a five-minute bin. It keys on
  `EventType in ("fail", "failed")`, not on `Success`.
- **Configuration change** - fires on `entityChange` events touching `services`,
  `service-policies`, `edge-router-policies`, or `identities`.

!!! warning "Success is not a reliable outcome flag"
    In OpenZiti v2.0.0 an authentication event can carry `event_type: "success"` while
    `success` is `false`, so the boolean is not a reliable outcome flag. Key your own
    detections on `EventType`, not `Success`.

The workbook has three panels: event volume by namespace over time, authentication success
vs failure, and configuration changes by entity type.

## Try it yourself

You do not need a controller to exercise the Azure half of the pipeline. Push the canonical
sample events straight onto the queue, then query what landed:

```bash
pip install azure-servicebus                 # a venv is fine
python scripts/inject_sample_events.py       # one batch; pass a count to send more
./scripts/verify.sh                          # summarise landed events by namespace and type
```

*[DCR]: Data Collection Rule
*[DCE]: Data Collection Endpoint
*[SAS]: Shared Access Signature
*[KQL]: Kusto Query Language
*[ACI]: Azure Container Instances
