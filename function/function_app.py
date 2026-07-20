import json
import logging
import os

import azure.functions as func
from azure.identity import DefaultAzureCredential
from azure.monitor.ingestion import LogsIngestionClient
from shared import shape

app = func.FunctionApp()

_credential = DefaultAzureCredential()
_logs_client = LogsIngestionClient(
    endpoint=os.environ["LOGS_DCE_ENDPOINT"], credential=_credential
)
_DCR_ID = os.environ["LOGS_DCR_IMMUTABLE_ID"]
_STREAM = os.environ["LOGS_STREAM_NAME"]


@app.service_bus_queue_trigger(
    arg_name="msg", queue_name="openziti-events", connection="ServiceBusConnection"
)
def forward_to_sentinel(msg: func.ServiceBusMessage):
    event = json.loads(msg.get_body().decode("utf-8"))
    record = shape(event)
    _logs_client.upload(rule_id=_DCR_ID, stream_name=_STREAM, logs=[record])
    logging.info("uploaded 1 record (%s) to %s", event.get("namespace"), _STREAM)
