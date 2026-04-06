#!/usr/bin/env bash
# =============================================================================
#  run_all.sh — CI orchestrator for all SSI test apps
#
#  Loops over every app in apps/, provisions a Windows EC2 via Terraform,
#  waits for SSM to be ready, runs setup + verify, then destroys the instance.
#
#  Required env vars:
#    DD_API_KEY       — Datadog API key
#    AWS_REGION       — AWS region (default: us-east-1)
#    DD_SITE          — Datadog site (default: datadoghq.com)
#
#  Optional:
#    APP_FILTER       — only run apps matching this pattern (e.g. "dd-dog-runner")
#    SKIP_DESTROY     — set to "1" to leave instances running after the test
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
APPS_DIR="$REPO_ROOT/apps"
REGION="${AWS_REGION:-us-east-1}"
DD_SITE="${DD_SITE:-datadoghq.com}"
APP_FILTER="${APP_FILTER:-}"
SKIP_DESTROY="${SKIP_DESTROY:-0}"

: "${DD_API_KEY:?DD_API_KEY env var is required}"

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo "[$(date +%H:%M:%S)] $*"; }
ok()   { echo "  [OK]   $*"; }
fail() { echo "  [FAIL] $*" >&2; }

wait_for_ssm() {
    local instance_id="$1"
    local max_wait=600   # 10 minutes — Windows boot takes a while
    local elapsed=0
    log "Waiting for SSM agent on $instance_id (up to ${max_wait}s)..."
    while [ $elapsed -lt $max_wait ]; do
        status=$(aws ssm describe-instance-information \
            --filters "Key=InstanceIds,Values=$instance_id" \
            --region "$REGION" \
            --query "InstanceInformationList[0].PingStatus" \
            --output text 2>/dev/null || echo "None")
        if [ "$status" = "Online" ]; then
            ok "SSM agent online"
            return 0
        fi
        sleep 15
        elapsed=$((elapsed + 15))
        echo -n "."
    done
    echo ""
    fail "Timed out waiting for SSM on $instance_id"
    return 1
}

run_ssm_command() {
    local instance_id="$1"
    local description="$2"
    shift 2
    local commands=("$@")

    log "SSM: $description"

    local cmd_json
    cmd_json=$(printf '%s\n' "${commands[@]}" | jq -R . | jq -s .)

    local cmd_id
    cmd_id=$(aws ssm send-command \
        --instance-ids "$instance_id" \
        --document-name "AWS-RunPowerShellScript" \
        --parameters "commands=$cmd_json" \
        --region "$REGION" \
        --comment "$description" \
        --query "Command.CommandId" \
        --output text)

    # Poll for completion
    local max_wait=600
    local elapsed=0
    while [ $elapsed -lt $max_wait ]; do
        status=$(aws ssm get-command-invocation \
            --command-id "$cmd_id" \
            --instance-id "$instance_id" \
            --region "$REGION" \
            --query "Status" \
            --output text 2>/dev/null || echo "Pending")
        case "$status" in
            Success)
                ok "$description"
                return 0 ;;
            Failed|Cancelled|TimedOut)
                fail "$description (SSM status: $status)"
                aws ssm get-command-invocation \
                    --command-id "$cmd_id" \
                    --instance-id "$instance_id" \
                    --region "$REGION" \
                    --query "StandardErrorContent" \
                    --output text 2>/dev/null || true
                return 1 ;;
        esac
        sleep 10
        elapsed=$((elapsed + 10))
    done
    fail "$description — timed out"
    return 1
}

# ── Main loop ─────────────────────────────────────────────────────────────────
overall_failed=0
results=()

for app_dir in "$APPS_DIR"/*/; do
    app_name="$(basename "$app_dir")"

    if [ -n "$APP_FILTER" ] && [[ "$app_name" != *"$APP_FILTER"* ]]; then
        log "Skipping $app_name (APP_FILTER=$APP_FILTER)"
        continue
    fi

    tf_dir="$app_dir/terraform"
    if [ ! -d "$tf_dir" ]; then
        log "No terraform/ in $app_name, skipping"
        continue
    fi

    log "========================================================"
    log "Testing: $app_name"
    log "========================================================"

    app_failed=0

    # ── Provision ──────────────────────────────────────────────────────────
    pushd "$tf_dir" > /dev/null

    terraform init -reconfigure -input=false \
        -backend=false 2>&1 | tail -3

    terraform apply -auto-approve -input=false \
        -var "dd_api_key=$DD_API_KEY" \
        -var "dd_site=$DD_SITE" \
        -var "region=$REGION" \
        || { fail "Terraform apply failed for $app_name"; app_failed=1; }

    if [ $app_failed -eq 0 ]; then
        INSTANCE_ID=$(terraform output -raw instance_id)
        PUBLIC_IP=$(terraform output -raw public_ip)
        ok "EC2 provisioned: $INSTANCE_ID ($PUBLIC_IP)"

        # ── Wait for SSM ───────────────────────────────────────────────────
        wait_for_ssm "$INSTANCE_ID" || app_failed=1

        # ── Verify ─────────────────────────────────────────────────────────
        if [ $app_failed -eq 0 ]; then
            run_ssm_command "$INSTANCE_ID" "Verify $app_name" \
                "C:\\ssi-test\\apps\\$app_name\\scripts\\verify.ps1 -TargetHost localhost -DDApiKey '$DD_API_KEY' -DDSite '$DD_SITE'" \
                || app_failed=1
        fi
    fi

    # ── Destroy ────────────────────────────────────────────────────────────
    if [ "$SKIP_DESTROY" != "1" ]; then
        log "Destroying $app_name..."
        terraform destroy -auto-approve -input=false \
            -var "dd_api_key=$DD_API_KEY" \
            -var "dd_site=$DD_SITE" \
            -var "region=$REGION" \
            || { fail "Terraform destroy failed for $app_name (manual cleanup may be needed)"; }
        ok "Destroyed $app_name"
    else
        log "SKIP_DESTROY=1 — leaving $app_name running at $PUBLIC_IP"
    fi

    popd > /dev/null

    if [ $app_failed -eq 0 ]; then
        results+=("PASS: $app_name")
    else
        results+=("FAIL: $app_name")
        overall_failed=$((overall_failed + 1))
    fi
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "========================================================"
echo "  RESULTS"
echo "========================================================"
for r in "${results[@]}"; do
    if [[ "$r" == PASS* ]]; then
        echo "  [OK]   $r"
    else
        echo "  [FAIL] $r"
    fi
done
echo "========================================================"

exit $overall_failed
