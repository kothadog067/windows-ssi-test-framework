# =============================================================================
#  dd-dotnet-framework — Verify Script
#  Validates SSI injection into a .NET Framework 4.8 app (DotnetFramework.exe).
#  The ddinjector dotnet.c detects Framework apps via PE COM descriptor.
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
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] ── $t" -ForegroundColor Cyan
}

function Test-DllInjected {
    param([string]$ProcessName, [string]$DllName = "ddinjector_x64.dll")
    $output = & tasklist /fi "imagename eq $ProcessName" /m $DllName 2>&1
    return ($output | Where-Object { $_ -match [regex]::Escape($ProcessName) }).Count -gt 0
}

function Test-SkipListClean {
    $skipProcs = @("datadogagent.exe","agent.exe","trace-agent.exe",
                   "process-agent.exe","system-probe.exe","security-agent.exe")
    $violations = @()
    foreach ($proc in $skipProcs) {
        $output = & tasklist /fi "imagename eq $proc" /m "ddinjector_x64.dll" 2>&1
        if ($output | Where-Object { $_ -match [regex]::Escape($proc) }) { $violations += $proc }
    }
    return $violations
}

$results = [ordered]@{
    timestamp    = (Get-Date -Format "o")
    target_host  = $TargetHost
    checks       = [ordered]@{}
    overall_pass = $false
}

# ── 1. Service status ─────────────────────────────────────────────────────────
Write-Section "SERVICE STATUS"
try {
    $svc     = Get-Service -Name "DDFrameworkSvc" -ErrorAction Stop
    $svcPass = ($svc.Status -eq "Running")
} catch { $svcPass = $false }
$results.checks["service_running"] = @{ service = "DDFrameworkSvc"; pass = $svcPass }
if ($svcPass) { Write-Ok "DDFrameworkSvc RUNNING" } else { Write-Fail "DDFrameworkSvc NOT running" }

# ── 2. HTTP health check ───────────────────────────────────────────────────────
Write-Section "HTTP HEALTH CHECK"
$healthPass = $false
for ($i = 1; $i -le 10; $i++) {
    try {
        $r = Invoke-WebRequest -Uri "http://${TargetHost}:8087/health" -UseBasicParsing -TimeoutSec $TimeoutSec
        if ($r.StatusCode -eq 200) {
            $body = $r.Content | ConvertFrom-Json
            $healthPass = ($body.status -eq "ok") -and ($body.framework -eq "net48")
            break
        }
    } catch {}
    if ($i -lt 10) { Start-Sleep -Seconds 3 }
}
$results.checks["health_8087"] = @{ uri = "http://${TargetHost}:8087/health"; pass = $healthPass }
if ($healthPass) { Write-Ok "Health endpoint OK on port 8087 (framework=net48)" }
else             { Write-Fail "Health endpoint NOT responding on port 8087" }

# ── 3. DLL injection — ddinjector_x64.dll in DotnetFramework.exe ──────────────
Write-Section "DLL INJECTION CHECK (DotnetFramework.exe — PE COM descriptor path)"
$dllPass = Test-DllInjected -ProcessName "DotnetFramework.exe"
$results.checks["dll_injection_framework"] = @{
    process = "DotnetFramework.exe"
    dll     = "ddinjector_x64.dll"
    pass    = $dllPass
    note    = "Detected via IMAGE_DIRECTORY_ENTRY_COM_DESCRIPTOR in PE header (dotnet.c)"
}
if ($dllPass) { Write-Ok "ddinjector_x64.dll loaded in DotnetFramework.exe (PE COM descriptor path confirmed)" }
else          { Write-Fail "ddinjector_x64.dll NOT found in DotnetFramework.exe — .NET Framework PE detection failed" }

# ── 4. Skip list check ────────────────────────────────────────────────────────
Write-Section "SKIP LIST CHECK"
$skipViolations = Test-SkipListClean
$skipPass       = ($skipViolations.Count -eq 0)
$results.checks["skiplist_clean"] = @{ pass = $skipPass; violations = $skipViolations }
if ($skipPass) { Write-Ok "Skip list clean" } else { Write-Fail "Skip list violation: $($skipViolations -join ', ')" }

# ── 5. APM trace validation ────────────────────────────────────────────────────
Write-Section "DD APM TRACE VALIDATION"
if (-not $DDApiKey) {
    Write-Warn "DD_API_KEY not set — skipping APM trace validation"
} else {
    for ($i = 1; $i -le 3; $i++) {
        try { Invoke-WebRequest -Uri "http://${TargetHost}:8087/health" -UseBasicParsing -TimeoutSec 5 | Out-Null } catch {}
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
            $q      = [Uri]::EscapeDataString("service:dotnet-framework-app")
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
    $results.checks["traces_received"] = @{ service = "dotnet-framework-app"; pass = $tracePass }
}

# ── Summary ────────────────────────────────────────────────────────────────────
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
