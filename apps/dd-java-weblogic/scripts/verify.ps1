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
try { $svc = Get-Service -Name "WlsvcDemoSvc" -ErrorAction Stop; $svcPass = ($svc.Status -eq "Running") }
catch { $svcPass = $false }
$results.checks["service_running"] = @{ service = "WlsvcDemoSvc"; pass = $svcPass }
if ($svcPass) { Write-OK "WlsvcDemoSvc RUNNING" } else { Write-Fail "WlsvcDemoSvc NOT running"; $failed++ }

# ── Health (process=wlsvc.exe verified) ──────────────────────────────────────
Write-Step "HTTP HEALTH CHECK"
$body = Invoke-WithRetry -Uri "http://${TargetHost}:8090/health" -TimeoutSec $TimeoutSec
$pass = $body -and $body.status -eq "ok" -and $body.process -eq "wlsvc.exe"
$results.checks["health_8090"] = @{ uri = "http://${TargetHost}:8090/health"; pass = $pass }
if ($pass) { Write-OK "Health OK (process=wlsvc.exe)" } else { Write-Fail "Health FAILED on port 8090"; $failed++ }

# ── DLL injection — wlsvc.exe (is_weblogic_service path) ─────────────────────
Write-Step "DLL INJECTION CHECK"
$dllPass = Test-DllInjected -ProcessName "wlsvc.exe"
$results.checks["dll_injection_wlsvc"] = @{
    process = "wlsvc.exe"; dll = "ddinjector_x64.dll"; pass = $dllPass
    note    = "Detected by is_weblogic_service() in java.c"
}
if ($dllPass) { Write-OK "ddinjector_x64.dll in wlsvc.exe (WebLogic injection confirmed)" }
else          { Write-Fail "ddinjector_x64.dll NOT in wlsvc.exe"; $failed++ }

# ── Skip list ────────────────────────────────────────────────────────────────
$violations = Test-SkipListClean
$skipPass   = ($violations.Count -eq 0)
$results.checks["skiplist_clean"] = @{ pass = $skipPass; violations = $violations }
if ($skipPass) { Write-OK "Skip list clean" } else { Write-Fail "Skip list violation: $($violations -join ', ')"; $failed++ }

# ── Traces ───────────────────────────────────────────────────────────────────
Write-Step "TRACE CHECK"
$tracePass = Invoke-TraceCheck -ServiceName "java-weblogic-app" -DDApiKey $DDApiKey -DDSite $DDSite -WaitForTracesSec $WaitForTracesSec
if ($null -ne $tracePass) { $results.checks["traces_received"] = @{ service = "java-weblogic-app"; pass = $tracePass } }

$pass = Save-Results -Results $results -AppName "dd-java-weblogic" -ScriptStart $scriptStart
if ($pass) { exit 0 } else { exit 1 }
