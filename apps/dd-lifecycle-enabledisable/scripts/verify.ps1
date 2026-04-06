# =============================================================================
#  dd-lifecycle-enabledisable — Verify Script
#  Three-phase lifecycle test:
#    Phase 1 (ENABLED):  verify ddinjector_x64.dll IS loaded in dotnet.exe
#    Phase 2 (DISABLED): uninstrument, restart, verify DLL is NOT loaded
#    Phase 3 (RE-ENABLED): instrument, restart, verify DLL IS loaded again
#
#  Standard interface: verify.ps1 [-TargetHost <ip>] [-DDApiKey <key>]
#                                  [-DDSite <site>] [-WaitForTracesSec <n>]
#  Exit 0 = all phases pass, Exit 1 = one or more phases failed.
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
function Log($m)        { Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $m" -ForegroundColor DarkGray }
function Write-Section($t) {
    Write-Host ""
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] ── $t" -ForegroundColor Cyan
}

$InstallerPath = "C:\Program Files\Datadog\Datadog Agent\bin\datadog-installer.exe"
$ServiceName   = "DDLifecycleTestSvc"

function Test-DllInjected {
    param([string]$ProcessName, [string]$DllName = "ddinjector_x64.dll")
    $output = & tasklist /fi "imagename eq $ProcessName" /m $DllName 2>&1
    return ($output | Where-Object { $_ -match [regex]::Escape($ProcessName) }).Count -gt 0
}

function Restart-TestService {
    Restart-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 8  # allow ddinjector to run on new process
}

$results = [ordered]@{
    timestamp    = (Get-Date -Format "o")
    target_host  = $TargetHost
    checks       = [ordered]@{}
    overall_pass = $false
}

# ── Phase 1: SSI ENABLED ──────────────────────────────────────────────────────
Write-Section "PHASE 1: SSI ENABLED — ddinjector_x64.dll should be IN dotnet.exe"

$phase1_dll = Test-DllInjected -ProcessName "dotnet.exe"
$results.checks["phase1_enabled_dll_present"] = @{
    phase  = "enabled"
    pass   = $phase1_dll
    expect = "ddinjector_x64.dll PRESENT in dotnet.exe"
}
if ($phase1_dll) { Write-Ok "Phase 1 PASS — ddinjector_x64.dll loaded in dotnet.exe (SSI enabled)" }
else             { Write-Fail "Phase 1 FAIL — ddinjector_x64.dll NOT found in dotnet.exe (SSI should be enabled)" }

# ── Phase 2: DISABLE SSI ──────────────────────────────────────────────────────
Write-Section "PHASE 2: SSI DISABLED — ddinjector_x64.dll should NOT be in dotnet.exe"

if (Test-Path $InstallerPath) {
    Log "Running: datadog-installer.exe apm uninstrument host"
    & $InstallerPath apm uninstrument host
    Write-Ok "SSI disabled via apm uninstrument host"
} else {
    Write-Warn "datadog-installer.exe not found at $InstallerPath — attempting manual disable"
    # Fallback: rename ddinjector to prevent injection
    $injectorPath = "C:\Program Files\Datadog\Datadog Agent\bin\ddinjector_x64.dll"
    if (Test-Path $injectorPath) {
        Rename-Item $injectorPath "$injectorPath.disabled" -ErrorAction SilentlyContinue
    }
}

Write-Host "  Restarting service to reflect disabled state..."
Restart-TestService

$phase2_dll = Test-DllInjected -ProcessName "dotnet.exe"
$results.checks["phase2_disabled_dll_absent"] = @{
    phase  = "disabled"
    pass   = (-not $phase2_dll)   # PASS means DLL is NOT present
    expect = "ddinjector_x64.dll ABSENT from dotnet.exe"
}
if (-not $phase2_dll) { Write-Ok "Phase 2 PASS — ddinjector_x64.dll NOT loaded after uninstrument (SSI disabled correctly)" }
else                  { Write-Fail "Phase 2 FAIL — ddinjector_x64.dll still loaded after uninstrument (SSI disable failed)" }

# ── Phase 3: RE-ENABLE SSI ────────────────────────────────────────────────────
Write-Section "PHASE 3: SSI RE-ENABLED — ddinjector_x64.dll should be back in dotnet.exe"

if (Test-Path $InstallerPath) {
    Log "Running: datadog-installer.exe apm instrument host"
    & $InstallerPath apm instrument host
    Write-Ok "SSI re-enabled via apm instrument host"
} else {
    Write-Warn "datadog-installer.exe not found — attempting manual re-enable"
    $injectorPath = "C:\Program Files\Datadog\Datadog Agent\bin\ddinjector_x64.dll.disabled"
    if (Test-Path $injectorPath) {
        Rename-Item $injectorPath ($injectorPath -replace '\.disabled$', '') -ErrorAction SilentlyContinue
    }
}

Write-Host "  Restarting service to pick up re-enabled SSI..."
Restart-TestService

$phase3_dll = Test-DllInjected -ProcessName "dotnet.exe"
$results.checks["phase3_reenabled_dll_present"] = @{
    phase  = "re-enabled"
    pass   = $phase3_dll
    expect = "ddinjector_x64.dll PRESENT in dotnet.exe"
}
if ($phase3_dll) { Write-Ok "Phase 3 PASS — ddinjector_x64.dll loaded after re-instrument (lifecycle complete)" }
else             { Write-Fail "Phase 3 FAIL — ddinjector_x64.dll NOT found after re-instrument (re-enable failed)" }

# ── HTTP health check ─────────────────────────────────────────────────────────
Write-Section "HTTP HEALTH CHECK (final state)"
$healthPass = $false
for ($i = 1; $i -le 5; $i++) {
    try {
        $r = Invoke-WebRequest -Uri "http://${TargetHost}:8088/health" -UseBasicParsing -TimeoutSec $TimeoutSec
        if ($r.StatusCode -eq 200) { $healthPass = $true; break }
    } catch {}
    Start-Sleep -Seconds 3
}
$results.checks["health_final"] = @{ uri = "http://${TargetHost}:8088/health"; pass = $healthPass }
if ($healthPass) { Write-Ok "Service still healthy after lifecycle test" }
else             { Write-Fail "Service health check failed after lifecycle test" }

# ── Summary ────────────────────────────────────────────────────────────────────
$elapsed = [math]::Round(((Get-Date) - $scriptStart).TotalSeconds)
$allPass = $true
foreach ($k in $results.checks.Keys) {
    if (-not $results.checks[$k].pass) { $allPass = $false }
}
$results.overall_pass = $allPass
$json = $results | ConvertTo-Json -Depth 5
Write-Output $json
$json | Out-File -FilePath (Join-Path (Get-Location) "results.json") -Encoding utf8 -Force

Write-Host ""
if ($failed -eq 0) { Write-Host "  ALL LIFECYCLE PHASES PASSED (${elapsed}s)" -ForegroundColor Green; exit 0 }
else               { Write-Host "  $failed LIFECYCLE PHASE(S) FAILED (${elapsed}s)" -ForegroundColor Red; exit 1 }
