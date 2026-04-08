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
try { $svc = Get-Service -Name "JavaProcrunSvc" -ErrorAction Stop; $svcPass = ($svc.Status -eq "Running") }
catch { $svcPass = $false }
$results.checks["service_running"] = @{ service = "JavaProcrunSvc"; pass = $svcPass }
if ($svcPass) { Write-OK "JavaProcrunSvc RUNNING" } else { Write-Fail "JavaProcrunSvc NOT running"; $failed++ }

# ── Health ───────────────────────────────────────────────────────────────────
Write-Step "HTTP HEALTH CHECK"
$body = Invoke-WithRetry -Uri "http://${TargetHost}:8083/health" -TimeoutSec $TimeoutSec
$pass = $body -and $body.status -eq "ok" -and $body.service -eq "java-procrun-app"
$results.checks["health_8083"] = @{ uri = "http://${TargetHost}:8083/health"; pass = $pass }
if ($pass) { Write-OK "Health OK on port 8083" } else { Write-Fail "Health FAILED on port 8083"; $failed++ }

# ── Ping endpoint (Apache Procrun keepalive — unique to procrun app) ──────────
Write-Step "PING ENDPOINT CHECK"
$pingBody = Invoke-WithRetry -Uri "http://${TargetHost}:8083/ping" -MaxAttempts 3 -TimeoutSec $TimeoutSec
$pingPass = $pingBody -and $pingBody.pong -eq $true
$results.checks["ping_endpoint"] = @{ uri = "http://${TargetHost}:8083/ping"; pass = $pingPass }
if ($pingPass) { Write-OK "Ping endpoint OK (pong=true)" } else { Write-Fail "Ping endpoint FAILED"; $failed++ }

# ── DLL injection — prunsrv.exe (Apache Commons Daemon, is_procrun_service) ──
Write-Step "DLL INJECTION CHECK"
$dllPass = Test-DllInjected -ProcessName "prunsrv.exe"
$results.checks["dll_injection_prunsrv"] = @{
    process = "prunsrv.exe"; dll = "ddinjector_x64.dll"; pass = $dllPass
    note    = "Detected by is_procrun_service() in java.c"
}
if ($dllPass) { Write-OK "ddinjector_x64.dll in prunsrv.exe (Procrun SSI confirmed)" }
else          { Write-Fail "ddinjector_x64.dll NOT in prunsrv.exe"; $failed++ }

# ── Skip list ────────────────────────────────────────────────────────────────
$violations = Test-SkipListClean
$skipPass   = ($violations.Count -eq 0)
$results.checks["skiplist_clean"] = @{ pass = $skipPass; violations = $violations }
if ($skipPass) { Write-OK "Skip list clean" } else { Write-Fail "Skip list violation: $($violations -join ', ')"; $failed++ }

# ── Traces ───────────────────────────────────────────────────────────────────
Write-Step "TRACE CHECK"
$tracePass = Invoke-TraceCheck -ServiceName "java-procrun-app" -DDApiKey $DDApiKey -DDSite $DDSite -WaitForTracesSec $WaitForTracesSec
if ($null -ne $tracePass) { $results.checks["traces_received"] = @{ service = "java-procrun-app"; pass = $tracePass } }

$pass = Save-Results -Results $results -AppName "dd-java-procrun" -ScriptStart $scriptStart
if ($pass) { exit 0 } else { exit 1 }
