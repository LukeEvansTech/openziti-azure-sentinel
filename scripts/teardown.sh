#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Resolve names from config + tfvars, not `terraform output`: a failed destroy
# still strips root outputs from state, and `terraform output -raw` then prints
# its "No outputs found" warning on stdout - which would become $RG and let the
# completion gate below pass against a name that can never exist.
# shellcheck disable=SC2016 # HCL interpolation for terraform console, not the shell
NAMES=$(echo 'jsonencode([var.subscription_id, local.rg_name, var.create_workspace ? "law-${var.prefix}-${var.location}" : ""])' |
    terraform -chdir=terraform console 2>/dev/null) || {
    echo "terraform console failed; cannot resolve names." >&2
    exit 1
}
SUB="" RG="" WS_NAME=""
{
    read -r SUB
    read -r RG
    read -r WS_NAME
} < <(jq -r 'fromjson | .[]' <<<"$NAMES" 2>/dev/null) || true

if ! [[ "$SUB" =~ ^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$ && "$RG" =~ ^rg-[A-Za-z0-9-]+$ ]]; then
    echo "Refusing to continue: resolved subscription '$SUB' / resource group '$RG' look wrong." >&2
    exit 1
fi
# Config can drift from what was deployed (a changed subscription, prefix or
# location). If the state still records the resource group, its ID must be the
# one resolved above, or the az fallback and the gate would act on a different
# group than destroy does.
state_rg_id() {
    local state
    state=$(terraform -chdir=terraform show -json 2>/dev/null) || return 1
    jq -er '[.values.root_module.resources[]? | select(.address == "azurerm_resource_group.this") | .values.id][0] // ""' <<<"$state" 2>/dev/null
}
if ! STATE_RG_ID=$(state_rg_id); then
    echo "Refusing to continue: could not read the resource group from terraform state." >&2
    exit 1
fi
WANT_RG_ID="/subscriptions/$SUB/resourceGroups/$RG"
if [ -n "$STATE_RG_ID" ] && [ "$(tr '[:upper:]' '[:lower:]' <<<"$STATE_RG_ID")" != "$(tr '[:upper:]' '[:lower:]' <<<"$WANT_RG_ID")" ]; then
    echo "Refusing to continue: state holds resource group '$STATE_RG_ID' but configuration resolves '$WANT_RG_ID'." >&2
    echo "Restore the deployed subscription_id/prefix/location in terraform.tfvars, then re-run." >&2
    exit 1
fi
# Every az call names the subscription: the CLI's default drifts between
# sessions, and a check against the wrong subscription reads exactly like a pass.

if terraform -chdir=terraform destroy -auto-approve; then
    echo "terraform destroy complete."
else
    echo "destroy failed or no state; falling back to blocking az group delete." >&2
    # No --no-wait: block until the delete actually finishes, so the completion
    # check below reflects reality rather than an in-flight async delete.
    az group delete --subscription "$SUB" --name "$RG" --yes || true
fi

# Completeness check: purge any soft-deleted workspace of the same name.
if [ -n "$WS_NAME" ]; then
    DELETED=$(az monitor log-analytics workspace list-deleted-workspaces --subscription "$SUB" \
        --query "[?name=='$WS_NAME'].name" -o tsv 2>/dev/null || echo "")
    if [ -n "$DELETED" ]; then
        echo "Purging soft-deleted workspace $WS_NAME ..."
        az monitor log-analytics workspace delete --subscription "$SUB" --force true \
            --resource-group "$RG" --workspace-name "$WS_NAME" --yes 2>/dev/null || true
    fi
fi

# Honest completion gate: claim success only on an explicit "false". An az
# error (expired login, MFA challenge, unknown subscription) yields no "false"
# and fails, as does a resource group that still exists.
EXISTS=$(az group exists --subscription "$SUB" --name "$RG" --output tsv 2>/dev/null || echo "error")
if [ "$EXISTS" != "false" ]; then
    echo "WARNING: resource group '$RG' in subscription $SUB: exists check returned '$EXISTS' - NOT clean." >&2
    echo "Investigate delete locks, resources in a failed state, or the az login, then re-run." >&2
    exit 1
fi
echo "Teardown complete - resource group '$RG' removed from subscription $SUB, nothing left behind."
