#!/usr/bin/env pwsh
# PowerShell twin of verify.sh: summarise landed events by namespace and type.
Set-Location (Join-Path $PSScriptRoot "..")

$ws = terraform -chdir=terraform output -raw workspace_id
if ($LASTEXITCODE -ne 0) { exit 1 }
# The Log Analytics query API wants the workspace customerId GUID, not the
# ARM resource ID.
$cid = az monitor log-analytics workspace show --ids $ws --query customerId -o tsv
if ($LASTEXITCODE -ne 0) { exit 1 }
az monitor log-analytics query -w $cid `
    --analytics-query "OpenZitiEvents_CL | summarize Events=count() by Namespace, EventType | order by Events desc" `
    -o table
exit $LASTEXITCODE
