#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
WS=$(terraform -chdir=terraform output -raw workspace_id)
CID=$(az monitor log-analytics workspace show --ids "$WS" --query customerId -o tsv)
az monitor log-analytics query -w "$CID" \
    --analytics-query "OpenZitiEvents_CL | summarize Events=count() by Namespace, EventType | order by Events desc" \
    -o table
