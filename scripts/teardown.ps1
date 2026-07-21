#!/usr/bin/env pwsh
# PowerShell twin of teardown.sh - same honest completion gate: success is
# only claimed once the resource group is actually gone.
Set-Location (Join-Path $PSScriptRoot "..")

function Get-TfOutput {
    param([string]$Name)
    $value = terraform -chdir=terraform output -raw $Name 2> $null
    if ($LASTEXITCODE -ne 0) { return "" }
    return "$value"
}

$rg = Get-TfOutput "resource_group_name"
$wsName = Get-TfOutput "workspace_name"

terraform -chdir=terraform destroy -auto-approve
if ($LASTEXITCODE -eq 0) {
    Write-Output "terraform destroy complete."
}
else {
    Write-Warning "destroy failed or no state; falling back to blocking az group delete."
    # No --no-wait: block until the delete actually finishes, so the completion
    # check below reflects reality rather than an in-flight async delete.
    if ($rg) { az group delete --name $rg --yes }
}

# Completeness check: purge any soft-deleted workspace of the same name.
if ($rg -and $wsName) {
    $deleted = az monitor log-analytics workspace list-deleted-workspaces `
        --query "[?name=='$wsName'].name" -o tsv 2> $null
    if ($deleted) {
        Write-Output "Purging soft-deleted workspace $wsName ..."
        az monitor log-analytics workspace delete --force true `
            --resource-group $rg --workspace-name $wsName --yes 2> $null
    }
}

# Honest completion gate: only claim success if the RG is actually gone, so a
# failed destroy AND a failed az fallback cannot masquerade as a clean
# teardown that a redeploy then collides with.
if ($rg -and ((az group exists --name $rg) -eq "true")) {
    Write-Warning "resource group '$rg' still exists after teardown - NOT clean."
    Write-Warning "Investigate delete locks or resources in a failed state, then re-run."
    exit 1
}
$rgLabel = if ($rg) { $rg } else { "<none>" }
Write-Output "Teardown complete - resource group '$rgLabel' removed, nothing left behind."
