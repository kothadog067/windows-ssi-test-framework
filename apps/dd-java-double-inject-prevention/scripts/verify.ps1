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

$ServiceName = "DDDoubleInjectTestSvc"

# ── Service ──────────────────────────────────────────────────────────────────
Write-Step "SERVICE STATUS"
try { $svc = Get-Service -Name $ServiceName -ErrorAction Stop; $svcPass = ($svc.Status -eq "Running") }
catch { $svcPass = $false }
$results.checks["service_running"] = @{ service = $ServiceName; pass = $svcPass }
if ($svcPass) { Write-OK "$ServiceName RUNNING" } else { Write-Fail "$ServiceName NOT running"; $failed++ }

# ── Double injection check via app-reported dd_agent_count ────────────────────
Write-Step "DOUBLE INJECTION CHECK (app-reported dd_agent_count)"
$healthData = Invoke-WithRetry -Uri "http://${TargetHost}:8089/health" -TimeoutSec $TimeoutSec
if ($healthData) {
    Write-OK "Health endpoint responding on port 8089"
    $agentCount = [int]($healthData.dd_agent_count)
    $jto        = $healthData.java_tool_options
    Write-Host "  JAVA_TOOL_OPTIONS: $jto" -ForegroundColor DarkGray
    Write-Host "  dd-java-agent references: $agentCount (expected: 1)" -ForegroundColor DarkGray
    $singleAgentPass = ($agentCount -eq 1)
    $results.checks["single_javaagent_only"] = @{
        pass              = $singleAgentPass
        dd_agent_count    = $agentCount
        java_tool_options = $jto
        expect            = "exactly 1 -javaagent reference (no double injection)"
    }
    if ($singleAgentPass) { Write-OK "Double injection PREVENTED — exactly 1 dd-java-agent (count=$agentCount)" }
    else                  { Write-Fail "Double injection DETECTED — $agentCount references found (expected 1)"; $failed++ }
} else {
    Write-Fail "Health endpoint not responding — cannot check dd_agent_count"
    $results.checks["single_javaagent_only"] = @{ pass = $false; note = "health endpoint unavailable" }
    $failed++
}

# ── JAVA_TOOL_OPTIONS registry check ─────────────────────────────────────────
Write-Step "REGISTRY CHECK (JAVA_TOOL_OPTIONS in service environment)"
try {
    $regVals = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName" `
                                -Name "Environment" -ErrorAction Stop
    $jtoLine = $regVals.Environment | Where-Object { $_ -like "JAVA_TOOL_OPTIONS=*" }
    if ($jtoLine) {
        $jtoVal   = $jtoLine -replace "^JAVA_TOOL_OPTIONS=", ""
        $jtoCount = ([regex]::Matches($jtoVal, "dd-java-agent")).Count
        Write-Host "  Registry JAVA_TOOL_OPTIONS: $jtoVal" -ForegroundColor DarkGray
        $regJtoPass = ($jtoCount -eq 1)
        $results.checks["registry_jto_single"] = @{
            pass           = $regJtoPass
            jto_value      = $jtoVal
            dd_agent_count = $jtoCount
            expect         = "exactly 1 dd-java-agent in JAVA_TOOL_OPTIONS"
        }
        if ($regJtoPass) { Write-OK "Registry: exactly 1 dd-java-agent in JAVA_TOOL_OPTIONS" }
        else             { Write-Fail "Registry: $jtoCount dd-java-agent references (double injection in registry!)"; $failed++ }
    } else {
        Write-Warn "JAVA_TOOL_OPTIONS not found in service registry environment"
        $results.checks["registry_jto_single"] = @{ pass = $false; note = "JAVA_TOOL_OPTIONS not in registry" }
        $failed++
    }
} catch {
    Write-Warn "Could not read service registry: $_"
    $results.checks["registry_jto_single"] = @{ pass = $false; note = "registry read failed" }
    $failed++
}

$pass = Save-Results -Results $results -AppName "dd-java-double-inject-prevention" -ScriptStart $scriptStart
if ($pass) { exit 0 } else { exit 1 }
