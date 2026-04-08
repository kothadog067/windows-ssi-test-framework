#!/usr/bin/env bash
# =============================================================================
#  show_results.sh — Consolidated results dashboard
#
#  Reads all results/<app>/results.json files written by verify.ps1 and prints
#  a single human-readable table so you can see every app's status at a glance
#  without opening individual folders.
#
#  Usage:
#    bash scripts/show_results.sh                # reads ./results/ directory
#    bash scripts/show_results.sh /path/to/results
#
#  Column meaning:
#    HEALTH     — any check whose key starts with "health"
#    SERVICE    — checks.service_running (or any key starting with "service_")
#    DLL_INJECT — any check whose key starts with "dll_injection"
#    SKIPLIST   — skiplist_clean / skiplist_no_violations / kafka_jvm_skip_list
#    TRACES     — traces_received / any key starting with "traces_"
#    RESULT     — overall_pass from results.json, plus first failing check name
#
#  Exit code:
#    0 — all apps passed (or no results found)
#    1 — one or more apps failed
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULTS_DIR="${1:-$REPO_ROOT/results}"

# ── Dependency check ─────────────────────────────────────────────────────────
if ! command -v jq &>/dev/null; then
    echo "ERROR: jq is required.  brew install jq  /  apt install jq"
    exit 1
fi

# ── ANSI colours ─────────────────────────────────────────────────────────────
GREEN='\033[32m'
RED='\033[31m'
YELLOW='\033[33m'
CYAN='\033[36m'
GRAY='\033[90m'
RESET='\033[0m'

# ── Header ───────────────────────────────────────────────────────────────────
echo ""
printf "${CYAN}%-32s  %-8s  %-8s  %-10s  %-8s  %-8s  %s${RESET}\n" \
    "APP" "HEALTH" "SERVICE" "DLL_INJECT" "SKIPLIST" "TRACES" "RESULT"
printf '%s\n' "$(printf '─%.0s' {1..96})"

total=0
passed=0
failed=0

# ── Per-app row ───────────────────────────────────────────────────────────────
for results_file in "$RESULTS_DIR"/*/results.json; do
    [[ -f "$results_file" ]] || continue
    app=$(basename "$(dirname "$results_file")")

    # Top-level fields
    overall=$(jq -r '.overall_pass // false'  "$results_file" 2>/dev/null)
    elapsed=$(jq -r '.elapsed_sec  // 0'      "$results_file" 2>/dev/null)

    # ── Health: true if ALL health_* checks pass, false if any fail, "-" if none
    health_pass=$(jq -r '
      [.checks | to_entries[]
        | select(.key | test("^health"))
        | .value.pass // empty] as $vals
      | if ($vals | length) == 0 then "null"
        elif ($vals | all) then "true"
        else "false" end
    ' "$results_file" 2>/dev/null)

    # ── Service: service_running.pass, or first service_* check, or "-"
    service_pass=$(jq -r '
      (.checks.service_running.pass //
       (.checks | to_entries[]
         | select(.key | test("^service_"))
         | .value.pass) //
       empty) // "null" | tostring
    ' "$results_file" 2>/dev/null | head -1)

    # ── DLL injection: true if ALL dll_injection_* pass, false if any fail
    dll_pass=$(jq -r '
      [.checks | to_entries[]
        | select(.key | test("^dll_injection"))
        | .value.pass // empty] as $vals
      | if ($vals | length) == 0 then "null"
        elif ($vals | all) then "true"
        else "false" end
    ' "$results_file" 2>/dev/null)

    # ── Skip list: first matching key
    skip_pass=$(jq -r '
      (.checks.skiplist_clean.pass //
       .checks.skiplist_no_violations.pass //
       .checks.kafka_jvm_skip_list.pass //
       empty) // "null" | tostring
    ' "$results_file" 2>/dev/null | head -1)

    # ── Traces: first traces_* check with a pass field
    trace_pass=$(jq -r '
      (.checks.traces_received.pass //
       (.checks | to_entries[]
         | select(.key | test("^traces_"))
         | .value.pass // empty) //
       empty) // "null" | tostring
    ' "$results_file" 2>/dev/null | head -1)

    # ── Format a cell: ✓ (green) / ✗ (red) / - (gray)
    fmt_cell() {
        local val="$1" width="${2:-8}"
        case "$val" in
            true)  printf "${GREEN}✓${RESET}%-$((width-1))s" "" ;;
            false) printf "${RED}✗${RESET}%-$((width-1))s"   "" ;;
            *)     printf "${GRAY}-${RESET}%-$((width-1))s"  "" ;;
        esac
    }

    # ── Result column
    if [[ "$overall" == "true" ]]; then
        result_col="${GREEN}PASS${RESET} (${elapsed}s)"
        ((passed++)) || true
    else
        first_fail=$(jq -r '
          [.checks | to_entries[]
            | select(.value.pass == false)
            | .key][0] // "unknown"
        ' "$results_file" 2>/dev/null)
        result_col="${RED}FAIL${RESET} ← ${first_fail}"
        ((failed++)) || true
    fi
    ((total++)) || true

    # ── Print the row
    printf "%-32s  " "$app"
    fmt_cell "$health_pass"  "  "
    fmt_cell "$service_pass" "  "
    fmt_cell "$dll_pass"     "  "
    fmt_cell "$skip_pass"    "  "
    fmt_cell "$trace_pass"   "  "
    printf "%b\n" "$result_col"
done

# ── Footer ───────────────────────────────────────────────────────────────────
printf '%s\n' "$(printf '─%.0s' {1..96})"

if [[ $total -eq 0 ]]; then
    echo "  No results found in: $RESULTS_DIR"
    echo "  (Run bash run_all.sh or individual verify.ps1 scripts first)"
    exit 0
fi

printf "  ${GREEN}Passed${RESET}: %d / %d   ${RED}Failed${RESET}: %d / %d\n" \
    "$passed" "$total" "$failed" "$total"
echo ""

[[ $failed -eq 0 ]]
