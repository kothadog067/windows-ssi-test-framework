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

# ── Service ──────────────────────────────────────────────────────────────────
Write-Step "SERVICE STATUS"
try { $svc = Get-Service -Name "DDFrameworkSvc" -ErrorAction Stop; $svcPass = ($svc.Status -eq "Running") }
catch { $svcPass = $false }
$results.checks["service_running"] = @{ service = "DDFrameworkSvc"; pass = $svcPass }
if ($svcPass) { Write-OK "DDFrameworkSvc RUNNING" } else { Write-Fail "DDFrameworkSvc NOT running"; $failed++ }

# ── Health (framework=net48 verified) ────────────────────────────────────────
Write-Step "HTTP HEALTH CHECK"
$body = Invoke-WithRetry -Uri "http://${TargetHost}:8087/health" -TimeoutSec $TimeoutSec
$pass = $body -and $body.status -eq "ok" -and $body.framework -eq "net48"
$results.checks["health_8087"] = @{ uri = "http://${TargetHost}:8087/health"; pass = $pass }
if ($pass) { Write-OK "Health OK (framework=net48)" } else { Write-Fail "Health FAILED on port 8087"; $failed++ }

# ── DLL injection — DotnetFramework.exe (PE COM descriptor path) ─────────────
Write-Step "DLL INJECTION CHECK"
$dllPass = Test-DllInjected -ProcessName "DotnetFramework.exe"
$results.checks["dll_injection_framework"] = @{
    process = "DotnetFramework.exe"; dll = "ddinjector_x64.dll"; pass = $dllPass
    note    = "Detected via IMAGE_DIRECTORY_ENTRY_COM_DESCRIPTOR in PE header (dotnet.c)"
}
if ($dllPass) { Write-OK "ddinjector_x64.dll in DotnetFramework.exe (PE COM descriptor path confirmed)" }
else          { Write-Fail "ddinjector_x64.dll NOT in DotnetFramework.exe"; $failed++ }

# ── Skip list ────────────────────────────────────────────────────────────────
$violations = Test-SkipListClean
$skipPass   = ($violations.Count -eq 0)
$results.checks["skiplist_clean"] = @{ pass = $skipPass; violations = $violations }
if ($skipPass) { Write-OK "Skip list clean" } else { Write-Fail "Skip list violation: $($violations -join ', ')"; $failed++ }

# ── Traces ───────────────────────────────────────────────────────────────────
Write-Step "TRACE CHECK"
$tracePass = Invoke-TraceCheck -ServiceName "dotnet-framework-app" -DDApiKey $DDApiKey -DDSite $DDSite -WaitForTracesSec $WaitForTracesSec
if ($null -ne $tracePass) { $results.checks["traces_received"] = @{ service = "dotnet-framework-app"; pass = $tracePass } }

$pass = Save-Results -Results $results -AppName "dd-dotnet-framework" -ScriptStart $scriptStart
if ($pass) { exit 0 } else { exit 1 }
