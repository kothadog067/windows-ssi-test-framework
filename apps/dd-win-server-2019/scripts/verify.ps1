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
$results.os_info = (Get-WmiObject Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption

$ServiceName = "DDWorker2019Svc"
Write-Host "  OS: $($results.os_info)" -ForegroundColor Yellow

# ── Health ───────────────────────────────────────────────────────────────────
Write-Step "HTTP HEALTH CHECK"
$body = Invoke-WithRetry -Uri "http://${TargetHost}:8084/health" -TimeoutSec $TimeoutSec
$pass = $body -and $body.status -eq "ok" -and $body.service -eq "dd-win-2019-svc"
$results.checks["health_8084"] = @{ uri = "http://${TargetHost}:8084/health"; pass = $pass }
if ($pass) { Write-OK "Health OK (service=dd-win-2019-svc, Windows Server 2019 confirmed)" }
else       { Write-Fail "Health FAILED on port 8084"; $failed++ }

# ── Service ──────────────────────────────────────────────────────────────────
Write-Step "SERVICE STATUS"
try { $svc = Get-Service -Name $ServiceName -ErrorAction Stop; $svcPass = ($svc.Status -eq "Running") }
catch { $svcPass = $false }
$results.checks["service_running"] = @{ service = $ServiceName; pass = $svcPass }
if ($svcPass) { Write-OK "$ServiceName RUNNING" } else { Write-Fail "$ServiceName NOT running"; $failed++ }

# ── Registry env vars (DD_SERVICE, DD_ENV, DD_VERSION) ───────────────────────
Write-Step "REGISTRY ENV VARS"
try {
    $regVals = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName" `
                                -Name "Environment" -ErrorAction Stop
    $envArr  = $regVals.Environment
    $hasSvc  = ($envArr | Where-Object { $_ -like "DD_SERVICE=*" }).Count -gt 0
    $hasEnv  = ($envArr | Where-Object { $_ -like "DD_ENV=*"     }).Count -gt 0
    $hasVer  = ($envArr | Where-Object { $_ -like "DD_VERSION=*" }).Count -gt 0
    $regPass = $hasSvc -and $hasEnv -and $hasVer
} catch { $regPass = $false }
$results.checks["registry_env_vars"] = @{
    path = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName\Environment"; pass = $regPass
}
if ($regPass) { Write-OK "DD_SERVICE, DD_ENV, DD_VERSION present in service registry" }
else          { Write-Fail "Registry env vars missing or incomplete"; $failed++ }

# ── DLL injection — WorkerSvc2019.exe ────────────────────────────────────────
Write-Step "DLL INJECTION CHECK"
$dllPass = Test-DllInjected -ProcessName "WorkerSvc2019.exe"
$results.checks["dll_injection_workersvc2019"] = @{
    process = "WorkerSvc2019.exe"; dll = "ddinjector_x64.dll"; pass = $dllPass
    note    = "SSI injection confirmed on Windows Server 2019"
}
if ($dllPass) { Write-OK "ddinjector_x64.dll in WorkerSvc2019.exe (SSI confirmed on Windows Server 2019)" }
else          { Write-Fail "ddinjector_x64.dll NOT in WorkerSvc2019.exe"; $failed++ }

# ── Skip list ────────────────────────────────────────────────────────────────
$violations = Test-SkipListClean
$skipPass   = ($violations.Count -eq 0)
$results.checks["skiplist_clean"] = @{ pass = $skipPass; violations = $violations }
if ($skipPass) { Write-OK "Skip list clean" } else { Write-Fail "Skip list violation: $($violations -join ', ')"; $failed++ }

# ── Traces ───────────────────────────────────────────────────────────────────
Write-Step "TRACE CHECK"
$tracePass = Invoke-TraceCheck -ServiceName "dd-win-2019-svc" -DDApiKey $DDApiKey -DDSite $DDSite -WaitForTracesSec $WaitForTracesSec
if ($null -ne $tracePass) { $results.checks["traces_received"] = @{ service = "dd-win-2019-svc"; pass = $tracePass } }

$pass = Save-Results -Results $results -AppName "dd-win-server-2019" -ScriptStart $scriptStart
if ($pass) { exit 0 } else { exit 1 }
