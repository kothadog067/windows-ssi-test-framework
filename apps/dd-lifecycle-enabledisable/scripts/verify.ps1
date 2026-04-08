param(
    [string]$TargetHost       = "localhost",
    [string]$DDApiKey         = $env:DD_API_KEY,
    [string]$DDSite           = $(if ($env:DD_SITE) { $env:DD_SITE } else { "datadoghq.com" }),
    [int]   $TimeoutSec       = 30,
    [int]   $WaitForTracesSec = 60
)

Import-Module "$PSScriptRoot\..\..\scripts\verify_common.psm1" -Force

$ErrorActionPreference = "Continue"
$scriptStart   = Get-Date
$failed        = 0
$results       = New-ResultsObject -TargetHost $TargetHost

$InstallerPath = "C:\Program Files\Datadog\Datadog Agent\bin\datadog-installer.exe"
$ServiceName   = "DDLifecycleTestSvc"

function Restart-TestService {
    Restart-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 8   # allow ddinjector to run on new process
}

# ── Phase 1: SSI ENABLED ──────────────────────────────────────────────────────
Write-Step "PHASE 1: SSI ENABLED — ddinjector_x64.dll should be IN dotnet.exe"
$phase1Dll = Test-DllInjected -ProcessName "dotnet.exe"
$results.checks["phase1_enabled_dll_present"] = @{
    phase = "enabled"; pass = $phase1Dll; expect = "ddinjector_x64.dll PRESENT in dotnet.exe"
}
if ($phase1Dll) { Write-OK "Phase 1 PASS — DLL loaded in dotnet.exe (SSI enabled)" }
else            { Write-Fail "Phase 1 FAIL — DLL NOT found in dotnet.exe (SSI should be enabled)"; $failed++ }

# ── Phase 2: DISABLE SSI ─────────────────────────────────────────────────────
Write-Step "PHASE 2: SSI DISABLED — ddinjector_x64.dll should NOT be in dotnet.exe"
if (Test-Path $InstallerPath) {
    Write-Host "  Running: datadog-installer.exe apm uninstrument host" -ForegroundColor DarkGray
    & $InstallerPath apm uninstrument host
    Write-OK "SSI disabled via apm uninstrument host"
} else {
    Write-Warn "datadog-installer.exe not found — attempting manual disable"
    $injectorPath = "C:\Program Files\Datadog\Datadog Agent\bin\ddinjector_x64.dll"
    if (Test-Path $injectorPath) {
        Rename-Item $injectorPath "$injectorPath.disabled" -ErrorAction SilentlyContinue
    }
}
Write-Host "  Restarting service to reflect disabled state..." -ForegroundColor DarkGray
Restart-TestService
$phase2Dll = Test-DllInjected -ProcessName "dotnet.exe"
$results.checks["phase2_disabled_dll_absent"] = @{
    phase = "disabled"; pass = (-not $phase2Dll); expect = "ddinjector_x64.dll ABSENT from dotnet.exe"
}
if (-not $phase2Dll) { Write-OK "Phase 2 PASS — DLL absent after uninstrument (SSI disabled correctly)" }
else                 { Write-Fail "Phase 2 FAIL — DLL still present after uninstrument"; $failed++ }

# ── Phase 3: RE-ENABLE SSI ───────────────────────────────────────────────────
Write-Step "PHASE 3: SSI RE-ENABLED — ddinjector_x64.dll should be back in dotnet.exe"
if (Test-Path $InstallerPath) {
    Write-Host "  Running: datadog-installer.exe apm instrument host" -ForegroundColor DarkGray
    & $InstallerPath apm instrument host
    Write-OK "SSI re-enabled via apm instrument host"
} else {
    Write-Warn "datadog-installer.exe not found — attempting manual re-enable"
    $injectorPath = "C:\Program Files\Datadog\Datadog Agent\bin\ddinjector_x64.dll.disabled"
    if (Test-Path $injectorPath) {
        Rename-Item $injectorPath ($injectorPath -replace '\.disabled$', '') -ErrorAction SilentlyContinue
    }
}
Write-Host "  Restarting service to pick up re-enabled SSI..." -ForegroundColor DarkGray
Restart-TestService
$phase3Dll = Test-DllInjected -ProcessName "dotnet.exe"
$results.checks["phase3_reenabled_dll_present"] = @{
    phase = "re-enabled"; pass = $phase3Dll; expect = "ddinjector_x64.dll PRESENT in dotnet.exe"
}
if ($phase3Dll) { Write-OK "Phase 3 PASS — DLL back after re-instrument (lifecycle complete)" }
else            { Write-Fail "Phase 3 FAIL — DLL NOT found after re-instrument"; $failed++ }

# ── HTTP health (final state after lifecycle) ─────────────────────────────────
Write-Step "HTTP HEALTH CHECK (final state)"
$body       = Invoke-WithRetry -Uri "http://${TargetHost}:8088/health" -MaxAttempts 5 -TimeoutSec $TimeoutSec
$healthPass = $body -and $body.status -eq "ok"
$results.checks["health_final"] = @{ uri = "http://${TargetHost}:8088/health"; pass = $healthPass }
if ($healthPass) { Write-OK "Service healthy after lifecycle test" }
else             { Write-Fail "Health check failed after lifecycle test"; $failed++ }

$pass = Save-Results -Results $results -AppName "dd-lifecycle-enabledisable" -ScriptStart $scriptStart
if ($pass) { exit 0 } else { exit 1 }
