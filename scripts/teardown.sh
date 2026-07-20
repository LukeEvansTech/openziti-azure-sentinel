#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

RG=$(terraform -chdir=terraform output -raw resource_group_name 2>/dev/null || echo "")
WS_NAME=$(terraform -chdir=terraform output -raw workspace_name 2>/dev/null || echo "")

if terraform -chdir=terraform destroy -auto-approve; then
    echo "terraform destroy complete."
else
    echo "destroy failed or no state; falling back to blocking az group delete." >&2
    # No --no-wait: block until the delete actually finishes, so the completion
    # check below reflects reality rather than an in-flight async delete.
    [ -n "$RG" ] && az group delete --name "$RG" --yes || true
fi

# Completeness check: purge any soft-deleted workspace of the same name.
if [ -n "$WS_NAME" ] && [ -n "$RG" ]; then
    DELETED=$(az monitor log-analytics workspace list-deleted-workspaces \
        --query "[?name=='$WS_NAME'].name" -o tsv 2>/dev/null || echo "")
    if [ -n "$DELETED" ]; then
        echo "Purging soft-deleted workspace $WS_NAME ..."
        az monitor log-analytics workspace delete --force true \
            --resource-group "$RG" --workspace-name "$WS_NAME" --yes 2>/dev/null || true
    fi
fi

# Honest completion gate: only claim success if the RG is actually gone. The old
# script printed "complete" unconditionally, masking a destroy that failed AND an
# az-fallback that failed - so a redeploy could then collide with leftovers.
if [ -n "$RG" ] && [ "$(az group exists --name "$RG" 2>/dev/null)" = "true" ]; then
    echo "WARNING: resource group '$RG' still exists after teardown - NOT clean." >&2
    echo "Investigate delete locks or resources in a failed state, then re-run." >&2
    exit 1
fi
echo "Teardown complete - resource group '${RG:-<none>}' removed, nothing left behind."
