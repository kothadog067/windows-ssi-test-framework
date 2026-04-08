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
try { $svc = Get-Service -Name "DDX86Svc" -ErrorAction Stop; $svcPass = ($svc.Status -eq "Running") }
catch { $svcPass = $false }
$results.checks["service_running"] = @{ service = "DDX86Svc"; pass = $svcPass }
if ($svcPass) { Write-OK "DDX86Svc RUNNING" } else { Write-Fail "DDX86Svc NOT running"; $failed++ }

# ── Health + 32-bit confirmation ─────────────────────────────────────────────
Write-Step "HTTP HEALTH CHECK (32-bit process confirmation)"
$body       = Invoke-WithRetry -Uri "http://${TargetHost}:8091/health" -TimeoutSec $TimeoutSec
$healthPass = $body -and $body.status -eq "ok"
$is32bit    = $body -and $body.is32bit -eq $true
$results.checks["health_8091"]      = @{ uri = "http://${TargetHost}:8091/health"; pass = $healthPass }
$results.checks["process_is_32bit"] = @{ pass = $is32bit; note = "is32bit flag from /health endpoint" }
if ($healthPass) { Write-OK "Health OK on port 8091" } else { Write-Fail "Health FAILED on port 8091"; $failed++ }
if ($is32bit)    { Write-OK "Process confirmed 32-bit (is32bit=true)" }
else             { Write-Warn "is32bit flag not set — process may not be 32-bit" }

# ── DLL injection — ddinjector_x86.dll in DotnetX86App.exe ──────────────────
# CRITICAL: 32-bit processes use ddinjector_x86.dll, NOT ddinjector_x64.dll!
Write-Step "DLL INJECTION CHECK (ddinjector_x86.dll — 32-bit injection path)"
$dllX86Pass = Test-DllInjected -ProcessName "DotnetX86App.exe" -DllName "ddinjector_x86.dll"
$dllX64Pass = Test-DllInjected -ProcessName "DotnetX86App.exe" -DllName "ddinjector_x64.dll"
$results.checks["dll_injection_x86"] = @{
    process = "DotnetX86App.exe"; dll = "ddinjector_x86.dll"; pass = $dllX86Pass
    note    = "32-bit process — ddinjector uses x86 variant"
}
$results.checks["dll_injection_x64_absent"] = @{
    process = "DotnetX86App.exe"; dll = "ddinjector_x64.dll"; pass = (-not $dllX64Pass)
    note    = "x64 DLL should NOT be in a 32-bit process"
}
if ($dllX86Pass) { Write-OK "ddinjector_x86.dll in DotnetX86App.exe (32-bit injection confirmed)" }
else             { Write-Fail "ddinjector_x86.dll NOT in DotnetX86App.exe"; $failed++ }
if (-not $dllX64Pass) { Write-OK "ddinjector_x64.dll correctly absent from 32-bit process" }
else                  { Write-Warn "ddinjector_x64.dll unexpectedly present in 32-bit process" }

# ── Skip list — check BOTH ddinjector_x86.dll and ddinjector_x64.dll ─────────
Write-Step "SKIP LIST CHECK (both ddinjector_x86.dll and ddinjector_x64.dll)"
$violations = Test-SkipListClean -CheckX86
$skipPass   = ($violations.Count -eq 0)
$results.checks["skiplist_clean"] = @{ pass = $skipPass; violations = $violations }
if ($skipPass) { Write-OK "Skip list clean (x86 + x64 DLLs)" }
else           { Write-Fail "Skip list violation: $($violations -join ', ')"; $failed++ }

# ── Traces ───────────────────────────────────────────────────────────────────
Write-Step "TRACE CHECK"
# Generate traffic before polling
1..3 | ForEach-Object {
    try { Invoke-WithRetry -Uri "http://${TargetHost}:8091/health" -MaxAttempts 2 -TimeoutSec 5 | Out-Null } catch {}
}
$tracePass = Invoke-TraceCheck -ServiceName "dotnet-x86-app" -DDApiKey $DDApiKey -DDSite $DDSite -WaitForTracesSec $WaitForTracesSec
if ($null -ne $tracePass) { $results.checks["traces_received"] = @{ service = "dotnet-x86-app"; pass = $tracePass } }

$pass = Save-Results -Results $results -AppName "dd-dotnet-x86" -ScriptStart $scriptStart
if ($pass) { exit 0 } else { exit 1 }
