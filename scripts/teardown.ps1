#!/usr/bin/env pwsh
# PowerShell twin of teardown.sh - same honest completion gate: success is
# only claimed on an explicit "false" from az group exists.
Set-Location (Join-Path $PSScriptRoot "..")

# Resolve names from config + tfvars, not `terraform output`: a failed destroy
# still strips root outputs from state, and `terraform output -raw` then prints
# its "No outputs found" warning on stdout - which would become $rg and let the
# completion gate below pass against a name that can never exist.
$expr = 'jsonencode([var.subscription_id, local.rg_name, var.create_workspace ? "law-${var.prefix}-${var.location}" : ""])'
$raw = $expr | terraform -chdir=terraform console 2> $null
if ($LASTEXITCODE -ne 0) {
    Write-Warning "terraform console failed; cannot resolve names."
    exit 1
}
$sub = ""; $rg = ""; $wsName = ""
try {
    # Console prints the jsonencode result as an HCL string literal: decode the
    # literal, then the JSON array inside it.
    # No @() wrapper: Windows PowerShell 5.1 emits the array as one object.
    $names = ("$raw" | ConvertFrom-Json) | ConvertFrom-Json
    if ($names.Count -eq 3) {
        $sub = "$($names[0])"; $rg = "$($names[1])"; $wsName = "$($names[2])"
    }
}
catch { $sub = ""; $rg = "" }

if (-not (($sub -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') -and
        ($rg -cmatch '^rg-[A-Za-z0-9-]+$'))) {
    Write-Warning "Refusing to continue: resolved subscription '$sub' / resource group '$rg' look wrong."
    exit 1
}
# Config can drift from what was deployed (a changed subscription, prefix or
# location). If the state still records the resource group, its ID must be the
# one resolved above, or the az fallback and the gate would act on a different
# group than destroy does.
$stateRgId = ""
$stateJson = terraform -chdir=terraform show -json 2> $null
$stateOk = $LASTEXITCODE -eq 0 -and $stateJson
if ($stateOk) {
    try {
        $state = ($stateJson -join "`n") | ConvertFrom-Json -ErrorAction Stop
        if ($state.values -and $state.values.root_module -and $state.values.root_module.resources) {
            $rgRes = $state.values.root_module.resources |
                Where-Object { $_.address -eq "azurerm_resource_group.this" } | Select-Object -First 1
            if ($rgRes) { $stateRgId = "$($rgRes.values.id)" }
        }
    }
    catch { $stateOk = $false }
}
if (-not $stateOk) {
    Write-Warning "Refusing to continue: could not read the resource group from terraform state."
    exit 1
}
$wantRgId = "/subscriptions/$sub/resourceGroups/$rg"
if ($stateRgId -and ($stateRgId -ine $wantRgId)) {
    Write-Warning "Refusing to continue: state holds resource group '$stateRgId' but configuration resolves '$wantRgId'."
    Write-Warning "Restore the deployed subscription_id/prefix/location in terraform.tfvars, then re-run."
    exit 1
}
# Every az call names the subscription: the CLI's default drifts between
# sessions, and a check against the wrong subscription reads exactly like a pass.

terraform -chdir=terraform destroy -auto-approve
if ($LASTEXITCODE -eq 0) {
    Write-Output "terraform destroy complete."
}
else {
    Write-Warning "destroy failed or no state; falling back to blocking az group delete."
    # No --no-wait: block until the delete actually finishes, so the completion
    # check below reflects reality rather than an in-flight async delete.
    az group delete --subscription $sub --name $rg --yes
}

# Completeness check: purge any soft-deleted workspace of the same name.
if ($wsName) {
    $deleted = az monitor log-analytics workspace list-deleted-workspaces --subscription $sub `
        --query "[?name=='$wsName'].name" -o tsv 2> $null
    if ($deleted) {
        Write-Output "Purging soft-deleted workspace $wsName ..."
        az monitor log-analytics workspace delete --subscription $sub --force true `
            --resource-group $rg --workspace-name $wsName --yes 2> $null
    }
}

# Honest completion gate: claim success only on an explicit "false". An az
# error (expired login, MFA challenge, unknown subscription) yields no "false"
# and fails, as does a resource group that still exists.
$exists = az group exists --subscription $sub --name $rg --output tsv 2> $null
if ($LASTEXITCODE -ne 0) { $exists = "error" }
$exists = "$exists".Trim()
if ($exists -cne "false") {
    Write-Warning "resource group '$rg' in subscription ${sub}: exists check returned '$exists' - NOT clean."
    Write-Warning "Investigate delete locks, resources in a failed state, or the az login, then re-run."
    exit 1
}
Write-Output "Teardown complete - resource group '$rg' removed from subscription $sub, nothing left behind."
