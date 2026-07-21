#!/usr/bin/env pwsh
# PowerShell twin of deploy.sh - same behaviour, same retry logic. Works in
# Windows PowerShell 5.1 and PowerShell 7+; failures are handled through
# $LASTEXITCODE because native commands do not throw.
Set-Location (Join-Path $PSScriptRoot "..")

az account show *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Error "Not logged into Azure CLI. Run: az login"
    exit 1
}

terraform -chdir=terraform init -input=false
if ($LASTEXITCODE -ne 0) { exit 1 }

# Apply with bounded retries. A redeploy soon after a teardown re-creates
# resources into the just-freed names, which hits transient "recently deleted,
# retry later" conflicts: Sentinel analytics-rule ids stay reserved for a short
# cooldown after deletion (409, or a create that Azure immediately reports as
# absent -> "Provider produced inconsistent result after apply"), and a
# just-deleted Y1 Consumption plan's quota is briefly reported as 0 (401
# "quota" on the App Service Plan). Both clear within a few minutes and
# terraform apply is idempotent, so retry rather than fail the whole run.
$applied = $false
foreach ($attempt in 1..5) {
    terraform -chdir=terraform apply -auto-approve
    if ($LASTEXITCODE -eq 0) {
        $applied = $true
        break
    }
    Write-Warning ("apply attempt $attempt failed (often transient " +
        "post-teardown conflicts: Sentinel rule-id cooldown / Y1 quota " +
        "release); retrying in 90s...")
    Start-Sleep -Seconds 90
}
if (-not $applied) {
    Write-Error "terraform apply failed after retries"
    exit 1
}

$funcApp = terraform -chdir=terraform output -raw function_app_name
if ($LASTEXITCODE -ne 0) { exit 1 }
Write-Output "Publishing function code to $funcApp ..."
$published = $false
foreach ($attempt in 1..3) {
    Push-Location function
    func azure functionapp publish $funcApp --python
    $publishExit = $LASTEXITCODE
    Pop-Location
    if ($publishExit -eq 0) {
        $published = $true
        break
    }
    Write-Warning "publish attempt $attempt failed (often RBAC propagation); retrying in 30s..."
    Start-Sleep -Seconds 30
}
if (-not $published) {
    Write-Error "func publish failed after retries"
    exit 1
}

Write-Output "Done. Run ./scripts/verify.ps1 to see events land."
$ctrl = terraform -chdir=terraform output -raw controller_fqdn 2> $null
if ($LASTEXITCODE -ne 0) { $ctrl = "" }
if ($ctrl) {
    Write-Output "Controller FQDN: $ctrl"
}
else {
    Write-Output ("Demo controller disabled (deploy_demo_controller = false) " +
        "- point your controller's Service Bus event sink at the queue.")
}
