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
try { $svc = Get-Service -Name "DDSelfContainedSvc" -ErrorAction Stop; $svcPass = ($svc.Status -eq "Running") }
catch { $svcPass = $false }
$results.checks["service_running"] = @{ service = "DDSelfContainedSvc"; pass = $svcPass }
if ($svcPass) { Write-OK "DDSelfContainedSvc RUNNING" } else { Write-Fail "DDSelfContainedSvc NOT running"; $failed++ }

# ── Health (mode=self-contained-single-file verified) ────────────────────────
Write-Step "HTTP HEALTH CHECK"
$body = Invoke-WithRetry -Uri "http://${TargetHost}:8086/health" -TimeoutSec $TimeoutSec
$pass = $body -and $body.status -eq "ok" -and $body.mode -eq "self-contained-single-file"
$results.checks["health_8086"] = @{ uri = "http://${TargetHost}:8086/health"; pass = $pass }
if ($pass) { Write-OK "Health OK (mode=self-contained-single-file)" } else { Write-Fail "Health FAILED on port 8086"; $failed++ }

# ── DLL injection — DotnetSelfContained.exe (PE bundle signature) ─────────────
Write-Step "DLL INJECTION CHECK"
$dllPass = Test-DllInjected -ProcessName "DotnetSelfContained.exe"
$results.checks["dll_injection_selfcontained"] = @{
    process = "DotnetSelfContained.exe"; dll = "ddinjector_x64.dll"; pass = $dllPass
    note    = "Detected via PE .data bundle signature in dotnet.c"
}
if ($dllPass) { Write-OK "ddinjector_x64.dll in DotnetSelfContained.exe (PE bundle path confirmed)" }
else          { Write-Fail "ddinjector_x64.dll NOT in DotnetSelfContained.exe"; $failed++ }

# ── Skip list ────────────────────────────────────────────────────────────────
$violations = Test-SkipListClean
$skipPass   = ($violations.Count -eq 0)
$results.checks["skiplist_clean"] = @{ pass = $skipPass; violations = $violations }
if ($skipPass) { Write-OK "Skip list clean" } else { Write-Fail "Skip list violation: $($violations -join ', ')"; $failed++ }

# ── Traces ───────────────────────────────────────────────────────────────────
Write-Step "TRACE CHECK"
$tracePass = Invoke-TraceCheck -ServiceName "dotnet-selfcontained-app" -DDApiKey $DDApiKey -DDSite $DDSite -WaitForTracesSec $WaitForTracesSec
if ($null -ne $tracePass) { $results.checks["traces_received"] = @{ service = "dotnet-selfcontained-app"; pass = $tracePass } }

$pass = Save-Results -Results $results -AppName "dd-dotnet-selfcontained" -ScriptStart $scriptStart
if ($pass) { exit 0 } else { exit 1 }
