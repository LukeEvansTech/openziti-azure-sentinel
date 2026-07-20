from shared import shape


def test_shape_uses_event_timestamp():
    event = {
        "namespace": "authentication",
        "timestamp": "2026-07-06T14:30:00Z",
        "event_type": "failed",
        "identity_id": "id42",
    }
    out = shape(event)
    assert out["TimeGenerated"] == "2026-07-06T14:30:00Z"
    assert out["RawData"] == event


def test_shape_synthesizes_timestamp_when_missing():
    event = {"namespace": "session", "event_type": "created"}
    out = shape(event)
    assert out["TimeGenerated"] is not None
    assert out["RawData"] == event
