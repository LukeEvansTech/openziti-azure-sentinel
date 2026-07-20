#!/usr/bin/env python3
"""Push canonical OpenZiti events straight onto the Service Bus queue.

Proves the Azure half of the pipeline independently of an OpenZiti controller.
Reads the send connection string and queue name from Terraform outputs.
Usage: python scripts/inject_sample_events.py [count]
"""

import json
import subprocess
import sys

from azure.servicebus import ServiceBusClient, ServiceBusMessage

SAMPLES = [
    {
        "namespace": "authentication",
        "event_src_id": "ctrl1",
        "timestamp": "2026-07-06T14:30:00Z",
        "event_type": "failed",
        "type": "updb",
        "authenticator_id": "auth01",
        "identity_id": "id42",
        "success": False,
        "reason": "invalid password",
    },
    {
        "namespace": "authentication",
        "event_src_id": "ctrl1",
        "timestamp": "2026-07-06T14:31:00Z",
        "event_type": "success",
        "type": "updb",
        "authenticator_id": "auth01",
        "identity_id": "id7",
        "success": True,
    },
    {
        "namespace": "apiSession",
        "event_src_id": "ctrl1",
        "timestamp": "2026-07-06T14:31:05Z",
        "event_type": "created",
        "id": "ck1",
        "identity_id": "id7",
        "ip_address": "198.51.100.5",
    },
    {
        "namespace": "entityChange",
        "event_src_id": "ctrl1",
        "timestamp": "2026-07-06T14:32:00Z",
        "eventId": "e1",
        "eventType": "created",
        "metadata": {"author": {"type": "identity", "id": "id7"}},
        "entityType": "services",
        "initialState": None,
        "finalState": {"id": "svc1", "name": "demo-service"},
    },
]


def tf_output(name: str) -> str:
    return subprocess.check_output(
        ["terraform", "-chdir=terraform", "output", "-raw", name], text=True
    ).strip()


def main() -> None:
    count = int(sys.argv[1]) if len(sys.argv) > 1 else 1
    conn = tf_output("servicebus_send_connection_string")
    queue = tf_output("queue_name")
    with ServiceBusClient.from_connection_string(conn) as client:
        sender = client.get_queue_sender(queue_name=queue)
        with sender:
            for _ in range(count):
                for ev in SAMPLES:
                    sender.send_messages(ServiceBusMessage(json.dumps(ev)))
    print(f"sent {count * len(SAMPLES)} messages to {queue}")


if __name__ == "__main__":
    main()
