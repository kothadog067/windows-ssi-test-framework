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
$ServiceName = "DDWorkerSvc"

# ── Health ───────────────────────────────────────────────────────────────────
Write-Step "HTTP HEALTH CHECK"
$body = Invoke-WithRetry -Uri "http://${TargetHost}:8084/health" -TimeoutSec $TimeoutSec
$pass = $body -and $body.status -eq "ok" -and $body.service -eq "dd-worker-svc"
$results.checks["health"] = @{ uri = "http://${TargetHost}:8084/health"; pass = $pass }
if ($pass) { Write-OK "Health OK" } else { Write-Fail "Health FAILED"; $failed++ }

# ── Service running ──────────────────────────────────────────────────────────
Write-Step "SERVICE STATUS"
try { $svc = Get-Service -Name $ServiceName -ErrorAction Stop; $svcPass = ($svc.Status -eq "Running") }
catch { $svcPass = $false }
$results.checks["service_running"] = @{ service = $ServiceName; pass = $svcPass }
if ($svcPass) { Write-OK "$ServiceName RUNNING" } else { Write-Fail "$ServiceName NOT running"; $failed++ }

# ── Registry env vars ────────────────────────────────────────────────────────
Write-Step "REGISTRY ENV VARS"
try {
    $regVals = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName" -Name "Environment" -ErrorAction Stop
    $envArr  = $regVals.Environment
    $regPass = ($envArr | Where-Object { $_ -like "DD_SERVICE=*" }).Count -gt 0 -and
               ($envArr | Where-Object { $_ -like "DD_ENV=*"     }).Count -gt 0 -and
               ($envArr | Where-Object { $_ -like "DD_VERSION=*" }).Count -gt 0
} catch { $regPass = $false }
$results.checks["registry_env_vars"] = @{ pass = $regPass }
if ($regPass) { Write-OK "Registry env vars present" } else { Write-Fail "Registry env vars missing"; $failed++ }

# ── DLL injection — WorkerSvc.exe ────────────────────────────────────────────
Write-Step "DLL INJECTION CHECK"
$dllPass = Test-DllInjected -ProcessName "WorkerSvc.exe"
$results.checks["dll_injection_workersvc"] = @{ process = "WorkerSvc.exe"; dll = "ddinjector_x64.dll"; pass = $dllPass }
if ($dllPass) { Write-OK "ddinjector_x64.dll in WorkerSvc.exe (sc.exe native svc SSI confirmed)" }
else          { Write-Fail "ddinjector_x64.dll NOT in WorkerSvc.exe"; $failed++ }

# ── Skip list ────────────────────────────────────────────────────────────────
$violations = Test-SkipListClean
$skipPass   = ($violations.Count -eq 0)
$results.checks["skiplist_clean"] = @{ pass = $skipPass; violations = $violations }
if ($skipPass) { Write-OK "Skip list clean" } else { Write-Fail "Skip list violation: $($violations -join ', ')"; $failed++ }

# ── Traces ───────────────────────────────────────────────────────────────────
Write-Step "TRACE CHECK"
$tracePass = Invoke-TraceCheck -ServiceName "dd-worker-svc" -DDApiKey $DDApiKey -DDSite $DDSite -WaitForTracesSec $WaitForTracesSec
if ($null -ne $tracePass) { $results.checks["traces_received"] = @{ service = "dd-worker-svc"; pass = $tracePass } }

$pass = Save-Results -Results $results -AppName "dd-dotnet-native-svc" -ScriptStart $scriptStart
if ($pass) { exit 0 } else { exit 1 }
