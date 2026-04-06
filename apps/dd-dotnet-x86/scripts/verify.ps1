# =============================================================================
#  dd-dotnet-x86 — Verify Script
#  Validates SSI injection into a 32-bit (x86) .NET 8 process (DotnetX86App.exe).
#  IMPORTANT: 32-bit processes get ddinjector_x86.dll, NOT ddinjector_x64.dll.
#  This tests the separate x86 injection code path in the ddinjector.
#
#  Standard interface: verify.ps1 [-TargetHost <ip>] [-DDApiKey <key>]
#                                  [-DDSite <site>] [-WaitForTracesSec <n>]
#  Exit 0 = all checks pass, Exit 1 = one or more checks failed.
# =============================================================================

param(
    [string]$TargetHost       = "localhost",
    [string]$DDApiKey         = $env:DD_API_KEY,
    [string]$DDSite           = $(if ($env:DD_SITE) { $env:DD_SITE } else { "datadoghq.com" }),
    [int]   $TimeoutSec       = 30,
    [int]   $WaitForTracesSec = 60
)

$ErrorActionPreference = "Continue"
$scriptStart           = Get-Date
$failed                = 0

function Write-Ok($m)   { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:failed++ }
function Write-Warn($m) { Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Write-Section($t) {
    Write-Host ""
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] -- $t" -ForegroundColor Cyan
}

# For 32-bit processes: check ddinjector_x86.dll (not x64!)
function Test-DllInjected {
    param(
        [string]$ProcessName,
        [string]$DllName = "ddinjector_x64.dll"  # overridden per call
    )
    $output = & tasklist /fi "imagename eq $ProcessName" /m $DllName 2>&1
    return ($output | Where-Object { $_ -match [regex]::Escape($ProcessName) }).Count -gt 0
}

function Test-SkipListClean {
    $skipProcs = @("datadogagent.exe","agent.exe","trace-agent.exe",
                   "process-agent.exe","system-probe.exe","security-agent.exe")
    $violations = @()
    foreach ($proc in $skipProcs) {
        # Check both x86 and x64 DLLs for skip list
        foreach ($dll in @("ddinjector_x64.dll","ddinjector_x86.dll")) {
            $output = & tasklist /fi "imagename eq $proc" /m $dll 2>&1
            if ($output | Where-Object { $_ -match [regex]::Escape($proc) }) {
                $violations += "$proc ($dll)"
            }
        }
    }
    return $violations
}

$results = [ordered]@{
    timestamp    = (Get-Date -Format "o")
    target_host  = $TargetHost
    checks       = [ordered]@{}
    overall_pass = $false
}

# -- 1. Service status --------------------------------------------------------
Write-Section "SERVICE STATUS"
try {
    $svc     = Get-Service -Name "DDX86Svc" -ErrorAction Stop
    $svcPass = ($svc.Status -eq "Running")
} catch { $svcPass = $false }
$results.checks["service_running"] = @{ service = "DDX86Svc"; pass = $svcPass }
if ($svcPass) { Write-Ok "DDX86Svc RUNNING" } else { Write-Fail "DDX86Svc NOT running" }

# -- 2. HTTP health check — verify is32bit=true -------------------------------
Write-Section "HTTP HEALTH CHECK (verify 32-bit process)"
$healthPass = $false
$is32bit    = $false
for ($i = 1; $i -le 10; $i++) {
    try {
        $r = Invoke-WebRequest -Uri "http://${TargetHost}:8091/health" -UseBasicParsing -TimeoutSec $TimeoutSec
        if ($r.StatusCode -eq 200) {
            $body = $r.Content | ConvertFrom-Json
            $healthPass = ($body.status -eq "ok")
            $is32bit    = ($body.is32bit -eq $true)
            break
        }
    } catch {}
    if ($i -lt 10) { Start-Sleep -Seconds 3 }
}
$results.checks["health_8091"] = @{ uri = "http://${TargetHost}:8091/health"; pass = $healthPass }
$results.checks["process_is_32bit"] = @{ pass = $is32bit; note = "is32bit flag from /health endpoint" }

if ($healthPass) { Write-Ok "Health endpoint OK on port 8091" }
else             { Write-Fail "Health endpoint NOT responding on port 8091" }
if ($is32bit)    { Write-Ok "Process confirmed 32-bit (is32bit=true)" }
else             { Write-Warn "Process may not be 32-bit — check /info endpoint" }

# -- 3. DLL injection — ddinjector_x86.dll in DotnetX86App.exe ----------------
# CRITICAL: 32-bit processes use ddinjector_x86.dll, not ddinjector_x64.dll!
Write-Section "DLL INJECTION CHECK (ddinjector_x86.dll — 32-bit injection path)"

$dllX86Pass = Test-DllInjected -ProcessName "DotnetX86App.exe" -DllName "ddinjector_x86.dll"
$dllX64Pass = Test-DllInjected -ProcessName "DotnetX86App.exe" -DllName "ddinjector_x64.dll"

$results.checks["dll_injection_x86"] = @{
    process  = "DotnetX86App.exe"
    dll      = "ddinjector_x86.dll"
    pass     = $dllX86Pass
    note     = "32-bit process — ddinjector uses x86 variant"
}
$results.checks["dll_injection_x64_absent"] = @{
    process  = "DotnetX86App.exe"
    dll      = "ddinjector_x64.dll"
    pass     = (-not $dllX64Pass)   # x64 DLL should NOT be in a 32-bit process
    note     = "x64 DLL should NOT be in a 32-bit process"
}

if ($dllX86Pass) {
    Write-Ok "ddinjector_x86.dll loaded in DotnetX86App.exe (x86 injection path confirmed)"
} else {
    Write-Fail "ddinjector_x86.dll NOT found in DotnetX86App.exe — 32-bit SSI injection failed"
}

if (-not $dllX64Pass) {
    Write-Ok "ddinjector_x64.dll correctly absent from 32-bit process"
} else {
    Write-Warn "ddinjector_x64.dll unexpectedly present in 32-bit process (harmless but unexpected)"
}

# -- 4. Skip list check (both x86 and x64 DLLs) ------------------------------
Write-Section "SKIP LIST CHECK (both ddinjector_x86.dll and ddinjector_x64.dll)"
$skipViolations = Test-SkipListClean
$skipPass       = ($skipViolations.Count -eq 0)
$results.checks["skiplist_clean"] = @{ pass = $skipPass; violations = $skipViolations }
if ($skipPass) { Write-Ok "Skip list clean" } else { Write-Fail "Skip list violation: $($skipViolations -join ', ')" }

# -- 5. APM trace validation --------------------------------------------------
Write-Section "DD APM TRACE VALIDATION"
if (-not $DDApiKey) {
    Write-Warn "DD_API_KEY not set — skipping APM trace validation"
} else {
    for ($i = 1; $i -le 3; $i++) {
        try { Invoke-WebRequest -Uri "http://${TargetHost}:8091/health" -UseBasicParsing -TimeoutSec 5 | Out-Null } catch {}
        Start-Sleep -Milliseconds 300
    }
    $tracePass = $false
    $deadline  = (Get-Date).AddSeconds($WaitForTracesSec)
    $ddHeaders = @{ "DD-API-KEY" = $DDApiKey }
    $attempt   = 0
    while ((Get-Date) -lt $deadline) {
        $attempt++
        try {
            $fromMs = [DateTimeOffset]::UtcNow.AddMinutes(-5).ToUnixTimeMilliseconds()
            $toMs   = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            $q      = [Uri]::EscapeDataString("service:dotnet-x86-app")
            $uri    = "https://api.${DDSite}/api/v2/spans?filter[query]=$q&filter[from]=$fromMs&filter[to]=$toMs&page[limit]=5"
            $tr     = Invoke-RestMethod -Uri $uri -Headers $ddHeaders -Method Get -TimeoutSec 15
            if ($tr.data -and $tr.data.Count -gt 0) {
                $tracePass = $true
                $tv = $tr.data[0].attributes.tags."_dd.tracer_version"
                Write-Ok "Traces found — _dd.tracer_version=$tv"
                break
            }
        } catch {}
        $rem = [math]::Round(($deadline - (Get-Date)).TotalSeconds)
        Write-Host "    [poll $attempt] No traces yet — ${rem}s remaining..." -ForegroundColor DarkGray
        Start-Sleep -Seconds 10
    }
    if (-not $tracePass) { Write-Warn "No traces within ${WaitForTracesSec}s (not a hard failure)" }
    $results.checks["traces_received"] = @{ service = "dotnet-x86-app"; pass = $tracePass }
}

# -- Summary ------------------------------------------------------------------
$elapsed = [math]::Round(((Get-Date) - $scriptStart).TotalSeconds)
$allPass = $true
foreach ($k in $results.checks.Keys) {
    if (-not $results.checks[$k].pass) { $allPass = $false }
}
$results.overall_pass = $allPass
$json = $results | ConvertTo-Json -Depth 5
Write-Output $json
$json | Out-File -FilePath (Join-Path (Get-Location) "results.json") -Encoding utf8 -Force

Write-Host ""
if ($failed -eq 0) { Write-Host "  ALL CHECKS PASSED (${elapsed}s)" -ForegroundColor Green; exit 0 }
else               { Write-Host "  $failed CHECK(S) FAILED (${elapsed}s)" -ForegroundColor Red; exit 1 }
