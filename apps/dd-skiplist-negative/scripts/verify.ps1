# =============================================================================
#  dd-skiplist-negative — Verify Script
#  NEGATIVE TEST: verifies that skip-listed processes from default-skiplist.yaml
#  are NOT instrumented by ddinjector_x64.dll.
#
#  Pass condition: NONE of the skip-listed processes have ddinjector_x64.dll loaded.
#  This is the inverse of the normal injection check.
#
#  Standard interface: verify.ps1 [-TargetHost <ip>] [-DDApiKey <key>]
#                                  [-DDSite <site>] [-WaitForTracesSec <n>]
#  Exit 0 = all checks pass (no violations), Exit 1 = one or more violations found.
# =============================================================================

param(
    [string]$TargetHost       = "localhost",
    [string]$DDApiKey         = $env:DD_API_KEY,
    [string]$DDSite           = $(if ($env:DD_SITE) { $env:DD_SITE } else { "datadoghq.com" }),
    [int]   $TimeoutSec       = 30,
    [int]   $WaitForTracesSec = 60
)

$ErrorActionPreference = "Continue"
$scriptStart           = Get-Date
$failed                = 0

function Write-Ok($m)   { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:failed++ }
function Write-Warn($m) { Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Write-Section($t) {
    Write-Host ""
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] ── $t" -ForegroundColor Cyan
}

$results = [ordered]@{
    timestamp    = (Get-Date -Format "o")
    target_host  = $TargetHost
    checks       = [ordered]@{}
    overall_pass = $false
}

# ── Skip list from default-skiplist.yaml (ddinjector source) ─────────────────
# This is the authoritative list of processes that must NEVER be instrumented.
# Source: src/policies/windows/default-skiplist.yaml in auto_inject repo.
$skipList = [ordered]@{
    # Datadog agent processes (must never self-instrument)
    "datadogagent.exe"    = "Datadog Agent main process"
    "agent.exe"           = "Datadog Agent (legacy name)"
    "trace-agent.exe"     = "Datadog Trace Agent"
    "process-agent.exe"   = "Datadog Process Agent"
    "system-probe.exe"    = "Datadog System Probe"
    "security-agent.exe"  = "Datadog Security Agent"
    "dogstatsd.exe"       = "Datadog DogStatsD"
    "agent-security.exe"  = "Datadog Security Agent (alt name)"
    # System processes (would be catastrophic to instrument)
    "lsass.exe"           = "Local Security Authority Subsystem"
    "csrss.exe"           = "Client/Server Runtime Subsystem"
    "winlogon.exe"        = "Windows Logon Process"
    "svchost.exe"         = "Service Host"
    "services.exe"        = "Service Control Manager"
    # Browsers (skip list includes these to avoid crashes)
    "chrome.exe"          = "Google Chrome"
    "msedge.exe"          = "Microsoft Edge"
    "firefox.exe"         = "Mozilla Firefox"
}

Write-Section "SKIP LIST ENFORCEMENT CHECK"
Write-Host "  Testing $($skipList.Count) processes from default-skiplist.yaml..." -ForegroundColor DarkGray
Write-Host "  PASS = ddinjector_x64.dll is NOT present in the process" -ForegroundColor DarkGray
Write-Host ""

$violations      = @()
$notRunning      = @()
$confirmedClean  = @()

foreach ($proc in $skipList.Keys) {
    $desc   = $skipList[$proc]
    # First check if the process is running at all
    $running = (Get-Process -Name ($proc -replace '\.exe$', '') -ErrorAction SilentlyContinue).Count -gt 0

    if (-not $running) {
        $notRunning += $proc
        Write-Host "  [SKIP] $proc — not running (${desc})" -ForegroundColor DarkGray
        continue
    }

    # Process IS running — verify the DLL is NOT loaded
    $output = & tasklist /fi "imagename eq $proc" /m "ddinjector_x64.dll" 2>&1
    $hasdll = ($output | Where-Object { $_ -match [regex]::Escape($proc) }).Count -gt 0

    if ($hasdll) {
        $violations += $proc
        Write-Fail "$proc — VIOLATED: ddinjector_x64.dll found in $proc (${desc})"
    } else {
        $confirmedClean += $proc
        Write-Ok "$proc — clean: ddinjector_x64.dll NOT loaded (${desc})"
    }
}

Write-Host ""
Write-Host "  Summary: $($confirmedClean.Count) clean, $($violations.Count) violation(s), $($notRunning.Count) not running" -ForegroundColor DarkGray

$skipPass = ($violations.Count -eq 0)
$results.checks["skiplist_no_violations"] = @{
    pass             = $skipPass
    violations       = $violations
    confirmed_clean  = $confirmedClean
    not_running      = $notRunning
    total_checked    = $skipList.Count
}

# ── Verify agent processes ARE running (otherwise skip list can't be tested) ──
Write-Section "AGENT PROCESS HEALTH"
$coreAgentProcs = @("datadogagent.exe", "trace-agent.exe")
foreach ($proc in $coreAgentProcs) {
    $running = (Get-Process -Name ($proc -replace '\.exe$', '') -ErrorAction SilentlyContinue).Count -gt 0
    if ($running) {
        Write-Ok "$proc is running (skip list test is valid)"
    } else {
        Write-Warn "$proc is NOT running — install Datadog Agent to get full skip list coverage"
    }
    $results.checks["agent_running_$($proc -replace '\.exe$','')"] = @{ process = $proc; running = $running; pass = $running }
}

# ── Check that notepad.exe canary is also clean ───────────────────────────────
Write-Section "CANARY PROCESS CHECK (notepad.exe)"
$notepadRunning = (Get-Process -Name "notepad" -ErrorAction SilentlyContinue).Count -gt 0
if ($notepadRunning) {
    $output = & tasklist /fi "imagename eq notepad.exe" /m "ddinjector_x64.dll" 2>&1
    $hasdll = ($output | Where-Object { $_ -match "notepad.exe" }).Count -gt 0
    if ($hasdll) {
        Write-Warn "notepad.exe has ddinjector_x64.dll loaded — notepad.exe may not be on skip list"
        $results.checks["canary_notepad"] = @{ pass = $false; note = "notepad.exe instrumented (not necessarily a bug)" }
    } else {
        Write-Ok "notepad.exe clean — not instrumented"
        $results.checks["canary_notepad"] = @{ pass = $true }
    }
} else {
    Write-Warn "notepad.exe not running — start via setup.ps1 for canary test"
    $results.checks["canary_notepad"] = @{ pass = $true; note = "not running, skipped" }
}

# ── Summary ────────────────────────────────────────────────────────────────────
$elapsed = [math]::Round(((Get-Date) - $scriptStart).TotalSeconds)
$allPass = $skipPass  # Only skip list violations cause failure
$results.overall_pass = $allPass

$json = $results | ConvertTo-Json -Depth 5
Write-Output $json
$json | Out-File -FilePath (Join-Path (Get-Location) "results.json") -Encoding utf8 -Force

Write-Host ""
if ($violations.Count -eq 0) {
    Write-Host "  ALL CHECKS PASSED — skip list enforced correctly (${elapsed}s)" -ForegroundColor Green
    exit 0
} else {
    Write-Host "  $($violations.Count) SKIP LIST VIOLATION(S) (${elapsed}s)" -ForegroundColor Red
    exit 1
}
