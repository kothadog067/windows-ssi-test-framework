# =============================================================================
#  dd-java-double-inject-prevention — Verify Script
#  Verifies that the ddinjector prevents loading dd-java-agent.jar twice when
#  JAVA_TOOL_OPTIONS already has -javaagent set.
#
#  Pass conditions:
#  1. Service is running
#  2. Health endpoint reports dd_agent_count == 1 (exactly ONE javaagent)
#  3. JAVA_TOOL_OPTIONS contains exactly one -javaagent reference to dd-java-agent
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

$ServiceName = "DDDoubleInjectTestSvc"

$results = [ordered]@{
    timestamp    = (Get-Date -Format "o")
    target_host  = $TargetHost
    checks       = [ordered]@{}
    overall_pass = $false
}

# ── 1. Service status ─────────────────────────────────────────────────────────
Write-Section "SERVICE STATUS"
try {
    $svc     = Get-Service -Name $ServiceName -ErrorAction Stop
    $svcPass = ($svc.Status -eq "Running")
} catch { $svcPass = $false }
$results.checks["service_running"] = @{ service = $ServiceName; pass = $svcPass }
if ($svcPass) { Write-Ok "$ServiceName RUNNING" } else { Write-Fail "$ServiceName NOT running" }

# ── 2. Health check — read dd_agent_count from the app ────────────────────────
Write-Section "DOUBLE INJECTION CHECK (via app-reported dd_agent_count)"
$healthData = $null
for ($i = 1; $i -le 10; $i++) {
    try {
        $r = Invoke-WebRequest -Uri "http://${TargetHost}:8089/health" -UseBasicParsing -TimeoutSec $TimeoutSec
        if ($r.StatusCode -eq 200) {
            $healthData = $r.Content | ConvertFrom-Json
            break
        }
    } catch {}
    if ($i -lt 10) { Start-Sleep -Seconds 3 }
}

if ($healthData) {
    Write-Ok "Health endpoint responding on port 8089"
    $agentCount = [int]($healthData.dd_agent_count)
    $jto        = $healthData.java_tool_options

    Write-Host "  JAVA_TOOL_OPTIONS: $jto" -ForegroundColor DarkGray
    Write-Host "  dd-java-agent references count: $agentCount" -ForegroundColor DarkGray

    # KEY CHECK: exactly 1 javaagent reference (pre-injected manual one)
    # If ddinjector double-injected, count would be 2+
    $singleAgentPass = ($agentCount -eq 1)
    $results.checks["single_javaagent_only"] = @{
        pass              = $singleAgentPass
        dd_agent_count    = $agentCount
        java_tool_options = $jto
        expect            = "exactly 1 -javaagent reference (no double injection)"
    }
    if ($singleAgentPass) {
        Write-Ok "Double injection PREVENTED — exactly 1 dd-java-agent reference (count=$agentCount)"
    } else {
        Write-Fail "Double injection DETECTED — $agentCount dd-java-agent references found (expected 1)"
    }
} else {
    Write-Fail "Health endpoint not responding — cannot check dd_agent_count"
    $results.checks["single_javaagent_only"] = @{ pass = $false; note = "health endpoint unavailable" }
}

# ── 3. JAVA_TOOL_OPTIONS registry check ───────────────────────────────────────
Write-Section "REGISTRY CHECK (JAVA_TOOL_OPTIONS in service environment)"
try {
    $regVals = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName" `
                                -Name "Environment" -ErrorAction Stop
    $envArr  = $regVals.Environment
    $jtoLine = $envArr | Where-Object { $_ -like "JAVA_TOOL_OPTIONS=*" }

    if ($jtoLine) {
        $jtoVal    = $jtoLine -replace "^JAVA_TOOL_OPTIONS=", ""
        $jtoCount  = ([regex]::Matches($jtoVal, "dd-java-agent")).Count

        Write-Host "  Registry JAVA_TOOL_OPTIONS: $jtoVal" -ForegroundColor DarkGray
        $regJtoPass = ($jtoCount -eq 1)
        $results.checks["registry_jto_single"] = @{
            pass           = $regJtoPass
            jto_value      = $jtoVal
            dd_agent_count = $jtoCount
            expect         = "exactly 1 dd-java-agent in JAVA_TOOL_OPTIONS"
        }
        if ($regJtoPass) { Write-Ok "Registry: exactly 1 dd-java-agent reference in JAVA_TOOL_OPTIONS" }
        else             { Write-Fail "Registry: $jtoCount dd-java-agent references in JAVA_TOOL_OPTIONS (double injection in registry!)" }
    } else {
        Write-Warn "JAVA_TOOL_OPTIONS not found in service registry environment"
        $results.checks["registry_jto_single"] = @{ pass = $false; note = "JAVA_TOOL_OPTIONS not in registry" }
    }
} catch {
    Write-Warn "Could not read service registry: $_"
    $results.checks["registry_jto_single"] = @{ pass = $false; note = "registry read failed: $_" }
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
if ($failed -eq 0) { Write-Host "  ALL CHECKS PASSED — double injection prevented (${elapsed}s)" -ForegroundColor Green; exit 0 }
else               { Write-Host "  $failed CHECK(S) FAILED (${elapsed}s)" -ForegroundColor Red; exit 1 }
