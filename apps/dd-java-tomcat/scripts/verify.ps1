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
Write-Step "TOMCAT SERVICE STATUS"
try { $svc = Get-Service -Name "Tomcat9" -ErrorAction Stop; $svcPass = ($svc.Status -eq "Running") }
catch { $svcPass = $false }
$results.checks["service_running"] = @{ service = "Tomcat9"; pass = $svcPass }
if ($svcPass) { Write-OK "Tomcat9 RUNNING" } else { Write-Fail "Tomcat9 NOT running"; $failed++ }

# ── Health ───────────────────────────────────────────────────────────────────
Write-Step "HTTP HEALTH CHECK"
$healthUri = "http://${TargetHost}:8085/dd-tomcat-demo/health.jsp"
$resp = Invoke-WithRetry -Uri $healthUri -TimeoutSec $TimeoutSec
$pass = $resp -ne $null
$results.checks["health_8085"] = @{ uri = $healthUri; pass = $pass }
if ($pass) { Write-OK "Tomcat health responding on port 8085" } else { Write-Fail "Tomcat health NOT responding"; $failed++ }

# Traffic for traces
1..3 | ForEach-Object {
    try { Invoke-WithRetry -Uri "http://${TargetHost}:8085/dd-tomcat-demo/" -MaxAttempts 2 -TimeoutSec 5 | Out-Null } catch {}
}

# ── DLL injection — tomcat9.exe (is_tomcat_exe path) ─────────────────────────
Write-Step "DLL INJECTION CHECK"
$dllPass = Test-DllInjected -ProcessName "tomcat9.exe"
$results.checks["dll_injection_tomcat9"] = @{ process = "tomcat9.exe"; dll = "ddinjector_x64.dll"; pass = $dllPass }
if ($dllPass) { Write-OK "ddinjector_x64.dll in tomcat9.exe (Tomcat SSI confirmed)" }
else          { Write-Fail "ddinjector_x64.dll NOT in tomcat9.exe"; $failed++ }

# ── Skip list ────────────────────────────────────────────────────────────────
$violations = Test-SkipListClean
$skipPass   = ($violations.Count -eq 0)
$results.checks["skiplist_clean"] = @{ pass = $skipPass; violations = $violations }
if ($skipPass) { Write-OK "Skip list clean" } else { Write-Fail "Skip list violation: $($violations -join ', ')"; $failed++ }

# ── Traces ───────────────────────────────────────────────────────────────────
Write-Step "TRACE CHECK"
$tracePass = Invoke-TraceCheck -ServiceName "java-tomcat-app" -DDApiKey $DDApiKey -DDSite $DDSite -WaitForTracesSec $WaitForTracesSec
if ($null -ne $tracePass) { $results.checks["traces_received"] = @{ service = "java-tomcat-app"; pass = $tracePass } }

$pass = Save-Results -Results $results -AppName "dd-java-tomcat" -ScriptStart $scriptStart
if ($pass) { exit 0 } else { exit 1 }
