#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if ! az account show >/dev/null 2>&1; then
    echo "Not logged into Azure CLI. Run: az login" >&2
    exit 1
fi

terraform -chdir=terraform init -input=false

# Apply with bounded retries. A redeploy soon after a teardown re-creates
# resources into the just-freed names, which hits transient "recently deleted,
# retry later" conflicts: Sentinel analytics-rule ids stay reserved for a short
# cooldown after deletion (409, or a create that Azure immediately reports as
# absent -> "Provider produced inconsistent result after apply"), and a
# just-deleted Y1 Consumption plan's quota is briefly reported as 0 (401 "quota"
# on the App Service Plan). Both clear within a few minutes and terraform apply
# is idempotent, so retry rather than fail the whole run.
applied=false
for attempt in 1 2 3 4 5; do
    if terraform -chdir=terraform apply -auto-approve; then
        applied=true
        break
    fi
    echo "apply attempt $attempt failed (often transient post-teardown conflicts: Sentinel rule-id cooldown / Y1 quota release); retrying in 90s..." >&2
    sleep 90
done
[ "$applied" = true ] || {
    echo "terraform apply failed after retries" >&2
    exit 1
}

FUNC=$(terraform -chdir=terraform output -raw function_app_name)
echo "Publishing function code to $FUNC ..."
published=false
for attempt in 1 2 3; do
    if (cd function && func azure functionapp publish "$FUNC" --python); then
        published=true
        break
    fi
    echo "publish attempt $attempt failed (often RBAC propagation); retrying in 30s..." >&2
    sleep 30
done
[ "$published" = true ] || {
    echo "func publish failed after retries" >&2
    exit 1
}

echo "Done. Run ./scripts/verify.sh to see events land."
CTRL=$(terraform -chdir=terraform output -raw controller_fqdn 2>/dev/null || echo "")
if [ -n "$CTRL" ]; then
    echo "Controller FQDN: $CTRL"
else
    echo "Demo controller disabled (deploy_demo_controller = false) - point your controller's Service Bus event sink at the queue."
fi
