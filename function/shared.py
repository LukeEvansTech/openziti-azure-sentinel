"""Pure event-shaping logic, unit-tested independently of the Functions runtime."""

from datetime import datetime, timezone


def shape(event: dict) -> dict:
    """Map an OpenZiti event to the DCR stream schema: TimeGenerated + RawData.

    Column projection (Namespace, EventType, ...) is done by the DCR transform,
    so this stays minimal and schema-stable across event types.
    """
    ts = event.get("timestamp") or datetime.now(timezone.utc).isoformat()
    return {"TimeGenerated": ts, "RawData": event}
