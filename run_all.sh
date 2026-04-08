#!/usr/bin/env bash
# =============================================================================
#  run_all.sh — CI orchestrator for all SSI test apps (parallel edition)
#
#  Each app runs in its own background subshell. Results are written to
#  per-app state files so the main process can render a live status table
#  and produce a JUnit XML report.
#
#  Required env vars:
#    DD_API_KEY       — Datadog API key
#
#  Optional env vars:
#    AWS_REGION       — AWS region          (default: us-east-1)
#    DD_SITE          — Datadog site         (default: datadoghq.com)
#    APP_FILTER       — only run apps whose names contain this string
#    SKIP_DESTROY     — set to "1" to leave instances running after tests
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Paths & global constants
# ---------------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_DIR="$REPO_ROOT/apps"
RESULTS_DIR="$REPO_ROOT/results"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
JUNIT_XML="$RESULTS_DIR/junit-${TIMESTAMP}.xml"

REGION="${AWS_REGION:-us-east-1}"
DD_SITE="${DD_SITE:-datadoghq.com}"
APP_FILTER="${APP_FILTER:-}"
SKIP_DESTROY="${SKIP_DESTROY:-0}"

: "${DD_API_KEY:?DD_API_KEY env var is required}"

# Map of background PIDs  ->  app_name  (populated in main loop)
declare -A PID_TO_APP=()
# Map of app_name -> state directory
declare -A APP_STATE_DIR=()

mkdir -p "$RESULTS_DIR"

# ---------------------------------------------------------------------------
# 1. Typed error codes
# ---------------------------------------------------------------------------
readonly EC_TERRAFORM_APPLY_FAILED="TERRAFORM_APPLY_FAILED"
readonly EC_SSM_TIMEOUT="SSM_TIMEOUT"
readonly EC_VERIFY_FAILED="VERIFY_FAILED"
readonly EC_TERRAFORM_DESTROY_FAILED="TERRAFORM_DESTROY_FAILED"
readonly EC_INTERRUPTED="INTERRUPTED"

# ---------------------------------------------------------------------------
# 2. Logging helpers  (all output goes to per-app log files in workers;
#    the main process only writes the status table to stdout)
# ---------------------------------------------------------------------------
_ts()   { date +%H:%M:%S; }
log()   { echo "[$(_ts)] $*"; }
ok()    { echo "[$(_ts)]  [OK]   $*"; }
fail()  { echo "[$(_ts)]  [FAIL] $*" >&2; }

# ---------------------------------------------------------------------------
# 3. State-file helpers
#    Each app worker writes small sentinel files under its state dir so the
#    main process can poll them without subprocess coordination.
#
#    State files:
#      status      — RUNNING | PASS | FAIL | INTERRUPTED
#      error_code  — typed error code (only on failure)
#      start_epoch — unix timestamp of worker start
#      end_epoch   — unix timestamp of worker end
#      instance_id — EC2 instance ID (written after apply)
#      tf_dir      — absolute path to the app's terraform directory
# ---------------------------------------------------------------------------
state_write() { echo "$2" > "$1/$3"; }   # state_write <dir> <value> <key>
state_read()  { cat "$1/$2" 2>/dev/null || echo ""; }

# ---------------------------------------------------------------------------
# 4. EXIT / INT / TERM trap
#    Marks every still-running worker as INTERRUPTED and issues
#    terraform destroy for any instance that was already provisioned.
# ---------------------------------------------------------------------------
_cleanup_triggered=0
cleanup() {
    [[ $_cleanup_triggered -eq 1 ]] && return
    _cleanup_triggered=1

    echo ""
    echo "[$(_ts)] *** Signal received — cleaning up all in-flight apps ***"

    for pid in "${!PID_TO_APP[@]}"; do
        local app="${PID_TO_APP[$pid]}"
        local sd="${APP_STATE_DIR[$app]}"
        local st
        st="$(state_read "$sd" status)"

        if [[ "$st" == "RUNNING" ]]; then
            state_write "$sd" "INTERRUPTED" status
            state_write "$sd" "$EC_INTERRUPTED" error_code
            # Signal the worker to stop
            kill -TERM "$pid" 2>/dev/null || true
        fi
    done

    # Give workers a moment to write their state, then force-destroy anything
    # that has an instance_id but hasn't been destroyed yet.
    sleep 3

    for app in "${!APP_STATE_DIR[@]}"; do
        local sd="${APP_STATE_DIR[$app]}"
        local instance_id
        instance_id="$(state_read "$sd" instance_id)"
        local tf_dir
        tf_dir="$(state_read "$sd" tf_dir)"

        if [[ -n "$instance_id" && -n "$tf_dir" && -d "$tf_dir" ]]; then
            echo "[$(_ts)] Emergency destroy: $app ($instance_id)"
            terraform -chdir="$tf_dir" destroy -auto-approve -input=false \
                -var "dd_api_key=$DD_API_KEY" \
                -var "dd_site=$DD_SITE" \
                -var "region=$REGION" \
                >> "$sd/terraform-destroy.log" 2>&1 || true
        fi
    done

    # Wait for any background pids that are still alive
    for pid in "${!PID_TO_APP[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# 5. SSM helpers
# ---------------------------------------------------------------------------
wait_for_ssm() {
    local instance_id="$1"
    local max_wait=600
    local elapsed=0
    log "Waiting for SSM agent on $instance_id (up to ${max_wait}s)…"
    while [[ $elapsed -lt $max_wait ]]; do
        local status
        status=$(aws ssm describe-instance-information \
            --filters "Key=InstanceIds,Values=$instance_id" \
            --region "$REGION" \
            --query "InstanceInformationList[0].PingStatus" \
            --output text 2>/dev/null || echo "None")
        if [[ "$status" == "Online" ]]; then
            ok "SSM agent online"
            return 0
        fi
        sleep 15
        elapsed=$((elapsed + 15))
    done
    fail "Timed out waiting for SSM on $instance_id"
    return 1
}

# run_ssm_command <instance_id> <description> <command...>
# Returns 0/1 and prints stdout/stderr to current log.
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

    local max_wait=600
    local elapsed=0
    while [[ $elapsed -lt $max_wait ]]; do
        local status
        status=$(aws ssm get-command-invocation \
            --command-id "$cmd_id" \
            --instance-id "$instance_id" \
            --region "$REGION" \
            --query "Status" \
            --output text 2>/dev/null || echo "Pending")
        case "$status" in
            Success)
                ok "$description"
                # Capture stdout for the caller
                aws ssm get-command-invocation \
                    --command-id "$cmd_id" \
                    --instance-id "$instance_id" \
                    --region "$REGION" \
                    --query "StandardOutputContent" \
                    --output text 2>/dev/null || true
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
    fail "$description — SSM poll timed out"
    return 1
}

# ---------------------------------------------------------------------------
# 6. Log collection via SSM
#    Gathers app logs, the DD agent log, and the Windows Application event log,
#    base64-encodes them into a single blob, ships it through SSM stdout,
#    then decodes and saves locally to results/<app>/logs/.
# ---------------------------------------------------------------------------
collect_logs() {
    local instance_id="$1"
    local log_dest="$2"   # local directory to write decoded logs into

    mkdir -p "$log_dest"
    log "Collecting remote logs from $instance_id → $log_dest"

    # PowerShell block: archive interesting paths, emit as base64 to stdout.
    # We build the archive entirely in memory (no temp files on disk) using
    # .NET's ZipArchive so there is no dependency on 7-zip or similar.
    local ps_collect
    ps_collect=$(cat <<'PS'
$ErrorActionPreference = "SilentlyContinue"
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$memStream = New-Object System.IO.MemoryStream
$archive   = New-Object System.IO.Compression.ZipArchive($memStream, [System.IO.Compression.ZipArchiveMode]::Create, $true)

function Add-FileToZip($zipArchive, $localPath, $entryName) {
    if (Test-Path $localPath -PathType Leaf) {
        $entry = $zipArchive.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Fastest)
        $entryStream = $entry.Open()
        $fileBytes = [System.IO.File]::ReadAllBytes($localPath)
        $entryStream.Write($fileBytes, 0, $fileBytes.Length)
        $entryStream.Close()
    }
}

# App logs
$appLogPaths = Get-ChildItem -Path "C:\dd-demo\*\logs\*.log" -Recurse -ErrorAction SilentlyContinue
foreach ($f in $appLogPaths) {
    $rel = $f.FullName.Substring("C:\dd-demo\".Length).Replace("\", "/")
    Add-FileToZip $archive $f.FullName "app-logs/$rel"
}

# Datadog agent log
Add-FileToZip $archive "C:\ProgramData\Datadog\logs\agent.log" "dd-agent/agent.log"

# Windows Application Event Log (last 100 entries) as CSV
$evtEntries = Get-EventLog -LogName Application -Newest 100 -ErrorAction SilentlyContinue |
    Select-Object TimeGenerated, EntryType, Source, EventID, Message |
    ConvertTo-Csv -NoTypeInformation
$evtEntry = $archive.CreateEntry("event-log/Application-last100.csv",
    [System.IO.Compression.CompressionLevel]::Fastest)
$evtStream  = $evtEntry.Open()
$evtBytes   = [System.Text.Encoding]::UTF8.GetBytes($evtEntries -join "`r`n")
$evtStream.Write($evtBytes, 0, $evtBytes.Length)
$evtStream.Close()

$archive.Dispose()
$memStream.Position = 0
$bytes = $memStream.ToArray()
$memStream.Dispose()

# Emit as base64 — SSM captures up to 48 000 bytes of stdout, so we
# chunk into 60-char lines (standard base64 line length).
[System.Convert]::ToBase64String($bytes) -replace '(.{60})', "`$1`n"
PS
)

    local raw_b64
    # We run the command and capture stdout directly.  run_ssm_command prints
    # stdout after the final 'Success' return, so we re-invoke the underlying
    # SSM plumbing here to capture just the output.
    local cmd_json
    cmd_json=$(echo "$ps_collect" | jq -Rs .)

    local cmd_id
    cmd_id=$(aws ssm send-command \
        --instance-ids "$instance_id" \
        --document-name "AWS-RunPowerShellScript" \
        --parameters "commands=[$cmd_json]" \
        --region "$REGION" \
        --comment "collect-logs" \
        --query "Command.CommandId" \
        --output text 2>/dev/null) || { fail "Could not send log-collection SSM command"; return 1; }

    local max_wait=300
    local elapsed=0
    local ssm_status="Pending"
    while [[ $elapsed -lt $max_wait ]]; do
        ssm_status=$(aws ssm get-command-invocation \
            --command-id "$cmd_id" \
            --instance-id "$instance_id" \
            --region "$REGION" \
            --query "Status" \
            --output text 2>/dev/null || echo "Pending")
        [[ "$ssm_status" == "Success" || "$ssm_status" == "Failed" ||
           "$ssm_status" == "Cancelled" || "$ssm_status" == "TimedOut" ]] && break
        sleep 10
        elapsed=$((elapsed + 10))
    done

    raw_b64=$(aws ssm get-command-invocation \
        --command-id "$cmd_id" \
        --instance-id "$instance_id" \
        --region "$REGION" \
        --query "StandardOutputContent" \
        --output text 2>/dev/null || echo "")

    if [[ -z "$raw_b64" ]]; then
        fail "No output from log-collection command (SSM status: $ssm_status)"
        return 1
    fi

    # Strip whitespace/newlines, then decode
    local clean_b64
    clean_b64=$(echo "$raw_b64" | tr -d '[:space:]')
    local zip_path="$log_dest/logs.zip"
    echo "$clean_b64" | base64 --decode > "$zip_path" 2>/dev/null \
        || { fail "base64 decode of remote log archive failed"; return 1; }

    # Unzip with the built-in 'unzip' (present on macOS/Linux CI runners)
    unzip -q -o "$zip_path" -d "$log_dest" 2>/dev/null \
        || { fail "unzip of log archive failed"; return 1; }
    rm -f "$zip_path"
    ok "Logs collected to $log_dest"
}

# ---------------------------------------------------------------------------
# 7. JUnit XML generation
#    Written only after all workers complete so we have final timings.
# ---------------------------------------------------------------------------
xml_escape() {
    # Escape the five XML special characters
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    s="${s//\"/&quot;}"
    s="${s//\'/&apos;}"
    echo "$s"
}

generate_junit() {
    local xml_file="$1"
    shift
    local app_names=("$@")

    local total=${#app_names[@]}
    local failures=0
    local total_time=0

    # First pass: gather counts
    for app in "${app_names[@]}"; do
        local sd="${APP_STATE_DIR[$app]}"
        local st
        st="$(state_read "$sd" status)"
        [[ "$st" != "PASS" ]] && failures=$((failures + 1))

        local t_start t_end elapsed_s
        t_start="$(state_read "$sd" start_epoch)"
        t_end="$(state_read "$sd" end_epoch)"
        if [[ -n "$t_start" && -n "$t_end" ]]; then
            elapsed_s=$((t_end - t_start))
            total_time=$((total_time + elapsed_s))
        fi
    done

    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo "<testsuites name=\"windows-ssi\" tests=\"$total\" failures=\"$failures\" time=\"$total_time\" timestamp=\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\">"
        echo "  <testsuite name=\"ssi-apps\" tests=\"$total\" failures=\"$failures\" time=\"$total_time\">"

        for app in "${app_names[@]}"; do
            local sd="${APP_STATE_DIR[$app]}"
            local st err_code elapsed_s

            st="$(state_read "$sd" status)"
            err_code="$(state_read "$sd" error_code)"

            local t_start t_end
            t_start="$(state_read "$sd" start_epoch)"
            t_end="$(state_read "$sd" end_epoch)"
            if [[ -n "$t_start" && -n "$t_end" ]]; then
                elapsed_s=$((t_end - t_start))
            else
                elapsed_s=0
            fi

            local safe_app
            safe_app="$(xml_escape "$app")"

            echo "    <testcase name=\"$safe_app\" classname=\"windows-ssi\" time=\"$elapsed_s\">"

            if [[ "$st" != "PASS" ]]; then
                # Include the last 30 lines of the main app log as the failure body
                local log_file="$sd/run.log"
                local last_lines=""
                if [[ -f "$log_file" ]]; then
                    last_lines="$(tail -30 "$log_file" 2>/dev/null || true)"
                fi
                local safe_msg safe_body
                safe_msg="$(xml_escape "${err_code:-UNKNOWN_FAILURE}")"
                safe_body="$(xml_escape "$last_lines")"
                echo "      <failure message=\"$safe_msg\">$safe_body</failure>"
            fi

            echo "    </testcase>"
        done

        echo "  </testsuite>"
        echo "</testsuites>"
    } > "$xml_file"

    log "JUnit XML written to $xml_file"
}

# ---------------------------------------------------------------------------
# 8. Live status table
#    Called in a loop by the main process while workers are running.
# ---------------------------------------------------------------------------
print_status_table() {
    local app_names=("$@")
    local now
    now=$(date +%s)

    # ANSI clear-to-end-of-screen after cursor
    printf '\033[2J\033[H'
    printf '%-30s  %-13s  %s\n' "APP" "STATUS" "ELAPSED"
    printf '%s\n' "$(printf '%.0s─' {1..55})"

    for app in "${app_names[@]}"; do
        local sd="${APP_STATE_DIR[$app]}"
        local st
        st="$(state_read "$sd" status)"
        local t_start elapsed_s="0"
        t_start="$(state_read "$sd" start_epoch)"

        if [[ -n "$t_start" ]]; then
            local t_end
            t_end="$(state_read "$sd" end_epoch)"
            if [[ -n "$t_end" ]]; then
                elapsed_s=$((t_end - t_start))
            else
                elapsed_s=$((now - t_start))
            fi
        fi

        local color reset='\033[0m' label
        case "$st" in
            PASS)        color='\033[32m' ; label="PASS        " ;;
            FAIL)        color='\033[31m' ; label="FAIL        " ;;
            INTERRUPTED) color='\033[33m' ; label="INTERRUPTED " ;;
            RUNNING)     color='\033[36m' ; label="RUNNING     " ;;
            *)           color='\033[37m' ; label="PENDING     " ;;
        esac

        printf "%-30s  ${color}%-13s${reset}  %dm%02ds\n" \
            "$app" "$label" $((elapsed_s / 60)) $((elapsed_s % 60))
    done
    printf '%s\n' "$(printf '%.0s─' {1..55})"
}

# ---------------------------------------------------------------------------
# 9. Per-app worker
#    Runs in a background subshell. All stdout/stderr redirected to run.log.
# ---------------------------------------------------------------------------
run_app() {
    local app_name="$1"
    local app_dir="$2"
    local state_dir="$3"
    local tf_dir="$app_dir/terraform"

    # All output goes to the per-app log.
    exec > "$state_dir/run.log" 2>&1

    state_write "$state_dir" "RUNNING" status
    state_write "$state_dir" "$(date +%s)" start_epoch
    state_write "$state_dir" "$tf_dir" tf_dir

    local app_failed=0
    local error_code=""
    local instance_id=""

    # ── Provision ────────────────────────────────────────────────────────────
    log "===== $app_name : terraform init ====="
    if ! terraform -chdir="$tf_dir" init \
            -reconfigure -input=false -backend=false 2>&1 | tail -5; then
        fail "terraform init failed"
        error_code="$EC_TERRAFORM_APPLY_FAILED"
        app_failed=1
    fi

    if [[ $app_failed -eq 0 ]]; then
        log "===== $app_name : terraform apply ====="
        if ! terraform -chdir="$tf_dir" apply \
                -auto-approve -input=false \
                -var "dd_api_key=$DD_API_KEY" \
                -var "dd_site=$DD_SITE" \
                -var "region=$REGION"; then
            fail "Terraform apply failed for $app_name"
            error_code="$EC_TERRAFORM_APPLY_FAILED"
            app_failed=1
        fi
    fi

    if [[ $app_failed -eq 0 ]]; then
        instance_id=$(terraform -chdir="$tf_dir" output -raw instance_id 2>/dev/null || echo "")
        local public_ip
        public_ip=$(terraform -chdir="$tf_dir" output -raw public_ip 2>/dev/null || echo "")
        ok "EC2 provisioned: $instance_id ($public_ip)"
        state_write "$state_dir" "$instance_id" instance_id

        # ── Wait for SSM ─────────────────────────────────────────────────────
        if ! wait_for_ssm "$instance_id"; then
            error_code="$EC_SSM_TIMEOUT"
            app_failed=1
        fi
    fi

    # ── Verify ───────────────────────────────────────────────────────────────
    if [[ $app_failed -eq 0 ]]; then
        log "===== $app_name : verify ====="
        if ! run_ssm_command "$instance_id" "Verify $app_name" \
            "C:\\ssi-test\\apps\\${app_name}\\scripts\\verify.ps1 -TargetHost localhost -DDApiKey '$DD_API_KEY' -DDSite '$DD_SITE'"; then
            error_code="$EC_VERIFY_FAILED"
            app_failed=1
        fi
    fi

    # ── Log collection ───────────────────────────────────────────────────────
    # Always attempt log collection when we have an instance, regardless of
    # pass/fail status or SKIP_DESTROY setting.
    if [[ -n "$instance_id" ]]; then
        log "===== $app_name : collecting logs ====="
        collect_logs "$instance_id" "$state_dir/logs" || true
    fi

    # ── Destroy ──────────────────────────────────────────────────────────────
    if [[ "$SKIP_DESTROY" != "1" ]] && [[ -n "$instance_id" || $app_failed -eq 1 ]]; then
        log "===== $app_name : terraform destroy ====="
        if ! terraform -chdir="$tf_dir" destroy \
                -auto-approve -input=false \
                -var "dd_api_key=$DD_API_KEY" \
                -var "dd_site=$DD_SITE" \
                -var "region=$REGION" \
                > "$state_dir/terraform-destroy.log" 2>&1; then
            fail "Terraform destroy failed for $app_name — manual cleanup may be needed"
            # Only override error code if we haven't already failed for another reason
            if [[ $app_failed -eq 0 ]]; then
                error_code="$EC_TERRAFORM_DESTROY_FAILED"
                app_failed=1
            fi
        else
            ok "Destroyed $app_name"
            # Clear instance_id once destroyed so the trap doesn't re-destroy
            state_write "$state_dir" "" instance_id
        fi
    else
        log "SKIP_DESTROY=1 — leaving $app_name running"
    fi

    # ── Write final state ────────────────────────────────────────────────────
    state_write "$state_dir" "$(date +%s)" end_epoch

    if [[ $app_failed -eq 0 ]]; then
        state_write "$state_dir" "PASS" status
        ok "$app_name PASSED"
    else
        state_write "$state_dir" "FAIL" status
        state_write "$state_dir" "$error_code" error_code
        fail "$app_name FAILED ($error_code)"
        exit 1
    fi

    exit 0
}

# ---------------------------------------------------------------------------
# 10. Discover apps
# ---------------------------------------------------------------------------
app_names=()
for app_dir in "$APPS_DIR"/*/; do
    [[ -d "$app_dir" ]] || continue
    app_name="$(basename "$app_dir")"

    if [[ -n "$APP_FILTER" ]] && [[ "$app_name" != *"$APP_FILTER"* ]]; then
        echo "[$(_ts)] Skipping $app_name (APP_FILTER=$APP_FILTER)"
        continue
    fi

    if [[ ! -d "$app_dir/terraform" ]]; then
        echo "[$(_ts)] No terraform/ in $app_name — skipping"
        continue
    fi

    app_names+=("$app_name")
done

if [[ ${#app_names[@]} -eq 0 ]]; then
    echo "[$(_ts)] No apps to run.  Check APPS_DIR=$APPS_DIR and APP_FILTER=$APP_FILTER"
    exit 0
fi

# ---------------------------------------------------------------------------
# 11. Launch workers in parallel
# ---------------------------------------------------------------------------
echo "[$(_ts)] Launching ${#app_names[@]} app(s) in parallel: ${app_names[*]}"

for app_name in "${app_names[@]}"; do
    app_dir="$APPS_DIR/$app_name"
    state_dir="$RESULTS_DIR/$app_name"
    mkdir -p "$state_dir"

    APP_STATE_DIR["$app_name"]="$state_dir"
    state_write "$state_dir" "PENDING" status

    # Launch worker as background subshell.
    # 'run_app' is defined above and redirects its own I/O.
    (run_app "$app_name" "$app_dir" "$state_dir") &
    local_pid=$!
    PID_TO_APP["$local_pid"]="$app_name"
    echo "[$(_ts)] Started $app_name (PID $local_pid)"
done

# ---------------------------------------------------------------------------
# 12. Live status table — refresh every 5 s while workers are running
# ---------------------------------------------------------------------------
all_done() {
    for app in "${app_names[@]}"; do
        local st
        st="$(state_read "${APP_STATE_DIR[$app]}" status)"
        [[ "$st" == "RUNNING" || "$st" == "PENDING" ]] && return 1
    done
    return 0
}

# Only render the table when stdout is a terminal
if [[ -t 1 ]]; then
    while ! all_done; do
        print_status_table "${app_names[@]}"
        sleep 5
    done
    # One final render
    print_status_table "${app_names[@]}"
fi

# ---------------------------------------------------------------------------
# 13. Collect worker exit codes
# ---------------------------------------------------------------------------
overall_failed=0
for pid in "${!PID_TO_APP[@]}"; do
    app="${PID_TO_APP[$pid]}"
    if ! wait "$pid"; then
        # Worker already wrote its own state; just count the failure
        overall_failed=$((overall_failed + 1))
    fi
done

# ---------------------------------------------------------------------------
# 14. Generate JUnit XML
# ---------------------------------------------------------------------------
generate_junit "$JUNIT_XML" "${app_names[@]}"

# ---------------------------------------------------------------------------
# 15. Final summary
# ---------------------------------------------------------------------------
echo ""
echo "========================================================"
echo "  RESULTS  ($(date '+%Y-%m-%d %H:%M:%S'))"
echo "========================================================"
printf '%-30s  %-13s  %-6s  %s\n' "APP" "STATUS" "TIME" "ERROR CODE"
printf '%s\n' "$(printf '%.0s─' {1..75})"

for app in "${app_names[@]}"; do
    sd="${APP_STATE_DIR[$app]}"
    st="$(state_read "$sd" status)"
    err="$(state_read "$sd" error_code)"

    t_start="$(state_read "$sd" start_epoch)"
    t_end="$(state_read "$sd" end_epoch)"
    elapsed_s=0
    if [[ -n "$t_start" && -n "$t_end" ]]; then
        elapsed_s=$((t_end - t_start))
    fi

    printf '%-30s  %-13s  %dm%02ds  %s\n' \
        "$app" "$st" $((elapsed_s / 60)) $((elapsed_s % 60)) "${err:--}"
done

printf '%s\n' "$(printf '%.0s─' {1..75})"
echo "  Passed : $((${#app_names[@]} - overall_failed)) / ${#app_names[@]}"
echo "  Failed : $overall_failed / ${#app_names[@]}"
echo "  JUnit  : $JUNIT_XML"
echo "  Logs   : $RESULTS_DIR/<app>/logs/"
echo "========================================================"

# ---------------------------------------------------------------------------
# 16. Consolidated check-level dashboard
# ---------------------------------------------------------------------------
if [[ -f "$REPO_ROOT/scripts/show_results.sh" ]]; then
    echo ""
    bash "$REPO_ROOT/scripts/show_results.sh" "$RESULTS_DIR" || true
fi

exit $overall_failed
