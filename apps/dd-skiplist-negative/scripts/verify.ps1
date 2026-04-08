param(
    [string]$TargetHost       = "localhost",
    [string]$DDApiKey         = $env:DD_API_KEY,
    [string]$DDSite           = $(if ($env:DD_SITE) { $env:DD_SITE } else { "datadoghq.com" }),
    [int]   $TimeoutSec       = 30,
    [int]   $WaitForTracesSec = 60
)

Import-Module "$PSScriptRoot\..\..\scripts\verify_common.psm1" -Force

$ErrorActionPreference = "Continue"
$scriptStart = Get-Date
$failed      = 0
$results     = New-ResultsObject -TargetHost $TargetHost

# ── Extended skip list from default-skiplist.yaml ─────────────────────────────
# Source: src/policies/windows/default-skiplist.yaml in auto_inject repo.
# This is the authoritative list of processes that must NEVER be instrumented.
$skipList = [ordered]@{
    "datadogagent.exe"   = "Datadog Agent main process"
    "agent.exe"          = "Datadog Agent (legacy name)"
    "trace-agent.exe"    = "Datadog Trace Agent"
    "process-agent.exe"  = "Datadog Process Agent"
    "system-probe.exe"   = "Datadog System Probe"
    "security-agent.exe" = "Datadog Security Agent"
    "dogstatsd.exe"      = "Datadog DogStatsD"
    "agent-security.exe" = "Datadog Security Agent (alt name)"
    "lsass.exe"          = "Local Security Authority Subsystem"
    "csrss.exe"          = "Client/Server Runtime Subsystem"
    "winlogon.exe"       = "Windows Logon Process"
    "svchost.exe"        = "Service Host"
    "services.exe"       = "Service Control Manager"
    "chrome.exe"         = "Google Chrome"
    "msedge.exe"         = "Microsoft Edge"
    "firefox.exe"        = "Mozilla Firefox"
}

# ── Skip list enforcement (PASS = DLL is NOT present) ────────────────────────
Write-Step "SKIP LIST ENFORCEMENT CHECK"
Write-Host "  Testing $($skipList.Count) processes from default-skiplist.yaml..." -ForegroundColor DarkGray
Write-Host "  PASS = ddinjector_x64.dll is NOT present in the process" -ForegroundColor DarkGray

$violations     = @()
$notRunning     = @()
$confirmedClean = @()

foreach ($proc in $skipList.Keys) {
    $desc    = $skipList[$proc]
    $running = (Get-Process -Name ($proc -replace '\.exe$', '') -ErrorAction SilentlyContinue).Count -gt 0

    if (-not $running) {
        $notRunning += $proc
        Write-Host "  [SKIP] $proc — not running ($desc)" -ForegroundColor DarkGray
        continue
    }

    $output = & tasklist /fi "imagename eq $proc" /m "ddinjector_x64.dll" 2>&1
    $hasDll = ($output | Where-Object { $_ -match [regex]::Escape($proc) }).Count -gt 0

    if ($hasDll) {
        $violations += $proc
        Write-Fail "$proc — VIOLATED: ddinjector_x64.dll found in $proc ($desc)"
        $failed++
    } else {
        $confirmedClean += $proc
        Write-OK "$proc — clean: ddinjector_x64.dll NOT loaded ($desc)"
    }
}

Write-Host ""
Write-Host "  Summary: $($confirmedClean.Count) clean, $($violations.Count) violation(s), $($notRunning.Count) not running" -ForegroundColor DarkGray

$skipPass = ($violations.Count -eq 0)
$results.checks["skiplist_no_violations"] = @{
    pass            = $skipPass
    violations      = $violations
    confirmed_clean = $confirmedClean
    not_running     = $notRunning
    total_checked   = $skipList.Count
}

# ── Agent process health (informational — ensures skip list test is valid) ────
Write-Step "AGENT PROCESS HEALTH"
foreach ($proc in @("datadogagent.exe", "trace-agent.exe")) {
    $running = (Get-Process -Name ($proc -replace '\.exe$', '') -ErrorAction SilentlyContinue).Count -gt 0
    if ($running) { Write-OK "$proc is running (skip list test is valid)" }
    else          { Write-Warn "$proc is NOT running — install Datadog Agent for full coverage" }
    # Informational: no "pass" key — Save-Results won't count this as a hard failure
    $results.checks["agent_running_$($proc -replace '\.exe$','')"] = @{ process = $proc; running = $running }
}

# ── Canary check (notepad.exe) ────────────────────────────────────────────────
Write-Step "CANARY PROCESS CHECK (notepad.exe)"
$notepadRunning = (Get-Process -Name "notepad" -ErrorAction SilentlyContinue).Count -gt 0
if ($notepadRunning) {
    $output = & tasklist /fi "imagename eq notepad.exe" /m "ddinjector_x64.dll" 2>&1
    $hasDll = ($output | Where-Object { $_ -match "notepad.exe" }).Count -gt 0
    if ($hasDll) { Write-Warn "notepad.exe is instrumented (may not be on skip list)" }
    else         { Write-OK "notepad.exe clean — not instrumented" }
    $results.checks["canary_notepad"] = @{ pass = $true; instrumented = $hasDll }
} else {
    Write-Warn "notepad.exe not running — start via setup.ps1 for canary test"
    $results.checks["canary_notepad"] = @{ pass = $true; note = "not running, skipped" }
}

$pass = Save-Results -Results $results -AppName "dd-skiplist-negative" -ScriptStart $scriptStart
if ($pass) { exit 0 } else { exit 1 }
