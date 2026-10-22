#!/usr/bin/env bash
# Runs scripts/teardown.sh (and scripts/teardown.ps1 when pwsh is available)
# against stub terraform/az binaries on PATH; makes no Azure calls.
# Usage: bash scripts/tests/test_teardown.sh
# Set REQUIRE_PWSH=1 to fail, rather than skip, when pwsh is missing.
# Override the scripts under test with TEARDOWN_SH / TEARDOWN_PS1.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEARDOWN_SH=${TEARDOWN_SH:-$ROOT/scripts/teardown.sh}
TEARDOWN_PS1=${TEARDOWN_PS1:-$ROOT/scripts/teardown.ps1}
STUBS="$(mktemp -d)" && [ -d "$STUBS" ] || {
    echo "mktemp failed" >&2
    exit 1
}
trap 'rm -rf "$STUBS"' EXIT

# What `terraform console` prints for the jsonencode expression: an HCL string literal.
GOOD_NAMES='"[\"00000000-0000-0000-0000-000000000000\",\"rg-ozsent-uksouth\",\"\"]"'
GOOD_NAMES_WS='"[\"00000000-0000-0000-0000-000000000000\",\"rg-ozsent-uksouth\",\"law-ozsent-uksouth\"]"'
# What `terraform output -raw` printed after a failed destroy wiped the outputs.
GARBAGE=$'\xe2\x95\xb7\n\xe2\x94\x82 Warning: No outputs found'
SUB_ARG="--subscription 00000000-0000-0000-0000-000000000000"

cat >"$STUBS/terraform" <<'EOF'
#!/usr/bin/env bash
echo "terraform $*" >>"$CALLS"
case "$*" in
    *console*) cat >/dev/null; printf '%s\n' "$TF_CONSOLE" ;;
    *destroy*) exit "$TF_DESTROY_RC" ;;
    *show*) [ "$TF_SHOW" = "error" ] && exit 1; printf '%s\n' "$TF_SHOW" ;;
    *output*) printf '%s\n' "$TF_CONSOLE" ;;
esac
EOF
cat >"$STUBS/az" <<'EOF'
#!/usr/bin/env bash
echo "az $*" >>"$CALLS"
case "$*" in
    "group exists"*) [ "$AZ_EXISTS" = "error" ] && exit 1; echo "$AZ_EXISTS" ;;
esac
exit 0
EOF
chmod +x "$STUBS/terraform" "$STUBS/az" || exit 1
# Never reach a real terraform or az: the scripts under test destroy things.
for tool in terraform az; do
    if [ "$(PATH="$STUBS:$PATH" command -v "$tool")" != "$STUBS/$tool" ]; then
        echo "stub $tool not first on PATH; refusing to run" >&2
        exit 1
    fi
done
state_with_rg_id() {
    printf '{"values":{"root_module":{"resources":[{"address":"azurerm_resource_group.this","values":{"id":"%s"}}]}}}' "$1"
}
STATE_SAME_RG=$(state_with_rg_id "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ozsent-uksouth")
STATE_OTHER_RG=$(state_with_rg_id "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-other-westeurope")
STATE_OTHER_SUB=$(state_with_rg_id "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-ozsent-uksouth")

fails=0
# case_ LABEL CONSOLE DESTROY_RC EXISTS WANT_RC [MUST_CALL] [MUST_NOT_CALL]
case_() {
    local name="$RUNNER_LABEL: $1" calls="$STUBS/calls" rc
    : >"$calls"
    CALLS=$calls TF_CONSOLE=$2 TF_DESTROY_RC=$3 AZ_EXISTS=$4 TF_SHOW=${TF_SHOW:-'{"format_version":"1.0"}'} PATH="$STUBS:$PATH" \
        run_script >/dev/null 2>&1 </dev/null
    rc=$?
    if [ "$rc" -ne "$5" ]; then
        echo "FAIL $name: exit $rc, want $5"
        fails=$((fails + 1))
        return
    fi
    if [ -n "${6:-}" ] && ! grep -q -- "$6" "$calls"; then
        echo "FAIL $name: no call matching '$6'"
        fails=$((fails + 1))
        return
    fi
    if [ -n "${7:-}" ] && grep -q -- "$7" "$calls"; then
        echo "FAIL $name: unexpected call matching '$7'"
        fails=$((fails + 1))
        return
    fi
    if grep '^az ' "$calls" | grep -qv -- "$SUB_ARG"; then
        echo "FAIL $name: an az call is missing $SUB_ARG"
        fails=$((fails + 1))
        return
    fi
    echo "ok   $name"
}

run_cases() {
    case_ "clean teardown passes" "$GOOD_NAMES" 0 false 0 "group exists $SUB_ARG"
    case_ "rg still present fails" "$GOOD_NAMES" 0 true 1
    case_ "az error is not clean" "$GOOD_NAMES" 0 error 1
    case_ "failed destroy falls back" "$GOOD_NAMES" 1 false 0 "group delete $SUB_ARG"
    case_ "garbage names refuse to destroy" "$GARBAGE" 0 false 1 "" "destroy"
    case_ "workspace purge check names the sub" "$GOOD_NAMES_WS" 0 false 0 "list-deleted-workspaces $SUB_ARG"
    TF_SHOW=$STATE_SAME_RG case_ "state rg matching config proceeds" "$GOOD_NAMES" 0 false 0 "destroy"
    TF_SHOW=$STATE_OTHER_RG case_ "state rg differing from config refuses" "$GOOD_NAMES" 0 false 1 "" "destroy"
    TF_SHOW=error case_ "unreadable state refuses" "$GOOD_NAMES" 0 false 1 "" "destroy"
    TF_SHOW='not json' case_ "undecodable state refuses" "$GOOD_NAMES" 0 false 1 "" "destroy"
    TF_SHOW=$STATE_OTHER_SUB case_ "state subscription differing from config refuses" "$GOOD_NAMES" 0 false 1 "" "destroy"
}

run_script() { bash "$TEARDOWN_SH"; }
RUNNER_LABEL=bash
run_cases

if command -v pwsh >/dev/null 2>&1; then
    run_script() { pwsh -NoProfile -NonInteractive -File "$TEARDOWN_PS1"; }
    RUNNER_LABEL=pwsh
    run_cases
elif [ "${REQUIRE_PWSH:-0}" = "1" ]; then
    echo "FAIL pwsh not found and REQUIRE_PWSH=1"
    fails=$((fails + 1))
else
    echo "skip pwsh: not installed, teardown.ps1 not exercised"
fi

if [ "$fails" -ne 0 ]; then
    echo "$fails failed"
    exit 1
fi
echo "all passed"
