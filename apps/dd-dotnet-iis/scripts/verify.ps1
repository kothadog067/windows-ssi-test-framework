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

# ── Health: port 80 ──────────────────────────────────────────────────────────
Write-Step "HTTP HEALTH CHECKS"
$body = Invoke-WithRetry -Uri "http://${TargetHost}:80/health" -TimeoutSec $TimeoutSec
$pass = $body -and $body.status -eq "ok" -and $body.service -eq "dotnet-iis-app"
$results.checks["health_port80"] = @{ uri = "http://${TargetHost}:80/health"; pass = $pass }
if ($pass) { Write-OK "Port 80 health OK" } else { Write-Fail "Port 80 health FAILED"; $failed++ }

# ── Health: port 8082 ────────────────────────────────────────────────────────
$body2 = Invoke-WithRetry -Uri "http://${TargetHost}:8082/health" -TimeoutSec $TimeoutSec
$pass2 = $body2 -and $body2.status -eq "ok"
$results.checks["health_port8082"] = @{ uri = "http://${TargetHost}:8082/health"; pass = $pass2 }
if ($pass2) { Write-OK "Port 8082 health OK" } else { Write-Fail "Port 8082 health FAILED"; $failed++ }

# ── Echo endpoint ────────────────────────────────────────────────────────────
$echo = Invoke-WithRetry -Uri "http://${TargetHost}:80/echo?msg=verify" -MaxAttempts 3 -TimeoutSec $TimeoutSec
$passEcho = $echo -and $echo.echo -eq "verify"
$results.checks["echo_endpoint"] = @{ pass = $passEcho }
if ($passEcho) { Write-OK "Echo endpoint OK" } else { Write-Fail "Echo endpoint FAILED"; $failed++ }

# ── IIS site + app pool ───────────────────────────────────────────────────────
Write-Step "IIS STATUS"
try {
    Import-Module WebAdministration -ErrorAction Stop
    $site    = Get-WebSite -Name "DDIisSite"
    $iisPass = ($site -ne $null) -and ($site.State -eq "Started")
} catch { $iisPass = $false }
$results.checks["iis_site_started"] = @{ site = "DDIisSite"; pass = $iisPass }
if ($iisPass) { Write-OK "DDIisSite started" } else { Write-Fail "DDIisSite NOT started"; $failed++ }

try {
    $pool     = Get-WebAppPoolState -Name "DDIisAppPool"
    $poolPass = ($pool.Value -eq "Started")
} catch { $poolPass = $false }
$results.checks["app_pool_started"] = @{ pool = "DDIisAppPool"; pass = $poolPass }
if ($poolPass) { Write-OK "DDIisAppPool started" } else { Write-Fail "DDIisAppPool NOT started"; $failed++ }

# ── DLL injection — w3wp.exe ──────────────────────────────────────────────────
Write-Step "DLL INJECTION CHECK"
$dllPass = Test-DllInjected -ProcessName "w3wp.exe"
$results.checks["dll_injection_w3wp"] = @{ process = "w3wp.exe"; dll = "ddinjector_x64.dll"; pass = $dllPass }
if ($dllPass) { Write-OK "ddinjector_x64.dll in w3wp.exe (IIS SSI confirmed)" }
else          { Write-Fail "ddinjector_x64.dll NOT in w3wp.exe"; $failed++ }

# ── Skip list ────────────────────────────────────────────────────────────────
$violations = Test-SkipListClean
$skipPass   = ($violations.Count -eq 0)
$results.checks["skiplist_clean"] = @{ pass = $skipPass; violations = $violations }
if ($skipPass) { Write-OK "Skip list clean" } else { Write-Fail "Skip list violation: $($violations -join ', ')"; $failed++ }

# ── Traces ───────────────────────────────────────────────────────────────────
Write-Step "TRACE CHECK"
$tracePass = Invoke-TraceCheck -ServiceName "dd-iis-app" -DDApiKey $DDApiKey -DDSite $DDSite -WaitForTracesSec $WaitForTracesSec
if ($null -ne $tracePass) { $results.checks["traces_received"] = @{ service = "dd-iis-app"; pass = $tracePass } }

$pass = Save-Results -Results $results -AppName "dd-dotnet-iis" -ScriptStart $scriptStart
if ($pass) { exit 0 } else { exit 1 }
