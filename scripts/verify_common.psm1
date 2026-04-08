# =============================================================================
#  verify_common.psm1 — Shared verification helpers for all SSI test apps
#
#  Usage in any app's verify.ps1:
#    Import-Module "$PSScriptRoot\..\..\scripts\verify_common.psm1" -Force
#
#  Exported functions:
#    Write-Step, Write-OK, Write-Fail, Write-Warn
#    New-ResultsObject
#    Invoke-WithRetry
#    Test-DllInjected
#    Test-SkipListClean
#    Invoke-TraceCheck
#    Save-Results
# =============================================================================

# ---------------------------------------------------------------------------
# Console helpers
# ---------------------------------------------------------------------------

function Write-Step {
    param([string]$Msg)
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] ── $Msg" -ForegroundColor Cyan
}
Export-ModuleMember -Function Write-Step

function Write-OK {
    param([string]$Msg)
    Write-Host "  [OK]   $Msg" -ForegroundColor Green
}
Export-ModuleMember -Function Write-OK

function Write-Fail {
    param([string]$Msg)
    Write-Host "  [FAIL] $Msg" -ForegroundColor Red
    # Increment caller's $script:failed counter if it exists
    try { $PSCmdlet.SessionState.PSVariable.Set("script:failed", (Get-Variable -Name "failed" -Scope 1 -ValueOnly -ErrorAction SilentlyContinue) + 1) } catch {}
}
Export-ModuleMember -Function Write-Fail

function Write-Warn {
    param([string]$Msg)
    Write-Host "  [WARN] $Msg" -ForegroundColor Yellow
}
Export-ModuleMember -Function Write-Warn

# ---------------------------------------------------------------------------
# New-ResultsObject — standard $results hashtable factory
# ---------------------------------------------------------------------------

function New-ResultsObject {
    param([string]$TargetHost = "localhost")
    return [ordered]@{
        timestamp    = (Get-Date -Format "o")
        target_host  = $TargetHost
        checks       = [ordered]@{}
        overall_pass = $false
    }
}
Export-ModuleMember -Function New-ResultsObject

# ---------------------------------------------------------------------------
# Invoke-WithRetry — HTTP request with retry/backoff
#   Returns parsed JSON body on success, $null on all-retry failure.
# ---------------------------------------------------------------------------

function Invoke-WithRetry {
    param(
        [string]$Uri,
        [string]$Method        = "GET",
        [string]$Body          = $null,
        [hashtable]$Headers    = @{},
        [int]   $MaxAttempts   = 10,
        [int]   $DelayMs       = 3000,
        [int]   $TimeoutSec    = 30,
        [string]$Label         = ""
    )
    for ($i = 1; $i -le $MaxAttempts; $i++) {
        try {
            $params = @{
                Uri             = $Uri
                Method          = $Method
                UseBasicParsing = $true
                TimeoutSec      = $TimeoutSec
                Headers         = $Headers
            }
            if ($Body) {
                $params.Body        = $Body
                $params.ContentType = "application/json"
            }
            $resp = Invoke-WebRequest @params
            return ($resp.Content | ConvertFrom-Json)
        } catch {
            if ($i -lt $MaxAttempts) {
                Start-Sleep -Milliseconds $DelayMs
            } else {
                if ($Label) { Write-Warn "$Label — all $MaxAttempts attempts failed: $_" }
                return $null
            }
        }
    }
    return $null
}
Export-ModuleMember -Function Invoke-WithRetry

# ---------------------------------------------------------------------------
# Test-DllInjected — checks if a DLL is loaded in a process via tasklist /m
#   This is the same mechanism as validate_injection_process.exe (GetModuleHandleA).
#   Returns $true if the DLL is found, $false otherwise.
# ---------------------------------------------------------------------------

function Test-DllInjected {
    param(
        [string]$ProcessName,
        [string]$DllName = "ddinjector_x64.dll"
    )
    $output = & tasklist /fi "imagename eq $ProcessName" /m $DllName 2>&1
    return ($output | Where-Object { $_ -match [regex]::Escape($ProcessName) }).Count -gt 0
}
Export-ModuleMember -Function Test-DllInjected

# ---------------------------------------------------------------------------
# Test-SkipListClean — returns list of DD agent processes that WRONGLY have
#   ddinjector_x64.dll loaded. Per default-skiplist.yaml these must never
#   be instrumented.
#   Pass $CheckX86 = $true for x86-aware checks (dd-dotnet-x86).
# ---------------------------------------------------------------------------

function Test-SkipListClean {
    param([switch]$CheckX86)
    $skipProcs = @(
        "datadogagent.exe",
        "agent.exe",
        "trace-agent.exe",
        "process-agent.exe",
        "system-probe.exe",
        "security-agent.exe"
    )
    $dlls = @("ddinjector_x64.dll")
    if ($CheckX86) { $dlls += "ddinjector_x86.dll" }

    $violations = @()
    foreach ($proc in $skipProcs) {
        foreach ($dll in $dlls) {
            $output = & tasklist /fi "imagename eq $proc" /m $dll 2>&1
            if ($output | Where-Object { $_ -match [regex]::Escape($proc) }) {
                $violations += if ($CheckX86) { "$proc ($dll)" } else { $proc }
            }
        }
    }
    return $violations
}
Export-ModuleMember -Function Test-SkipListClean

# ---------------------------------------------------------------------------
# Invoke-TraceCheck — polls the Datadog APM API v2 for spans from a service.
#   Returns $true if traces with _dd.tracer_version are found within the window.
# ---------------------------------------------------------------------------

function Invoke-TraceCheck {
    param(
        [string]$ServiceName,
        [string]$DDApiKey,
        [string]$DDSite          = "datadoghq.com",
        [int]   $WaitForTracesSec = 60
    )
    if (-not $DDApiKey) {
        Write-Warn "DD_API_KEY not set — skipping trace check for $ServiceName"
        return $null   # $null = skipped (not pass, not fail)
    }

    Write-Host "  Polling DD APM for traces from '$ServiceName' (up to ${WaitForTracesSec}s)..." -ForegroundColor DarkGray
    $ddHeaders = @{ "DD-API-KEY" = $DDApiKey }
    $deadline  = (Get-Date).AddSeconds($WaitForTracesSec)
    $attempt   = 0

    while ((Get-Date) -lt $deadline) {
        $attempt++
        try {
            $fromMs = [DateTimeOffset]::UtcNow.AddMinutes(-5).ToUnixTimeMilliseconds()
            $toMs   = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            $q      = [Uri]::EscapeDataString("service:$ServiceName env:demo")
            $uri    = "https://api.${DDSite}/api/v2/spans?filter[query]=$q&filter[from]=$fromMs&filter[to]=$toMs&page[limit]=5"
            $tr     = Invoke-RestMethod -Uri $uri -Headers $ddHeaders -Method Get -TimeoutSec 20

            if ($tr.data -and $tr.data.Count -gt 0) {
                $tv = $tr.data[0].attributes.tags."_dd.tracer_version"
                Write-OK "Traces found — _dd.tracer_version=$tv (SSI injection confirmed)"
                return $true
            }
        } catch {}
        $rem = [math]::Round(($deadline - (Get-Date)).TotalSeconds)
        Write-Host "    [poll $attempt] No traces yet — ${rem}s remaining..." -ForegroundColor DarkGray
        Start-Sleep -Seconds 10
    }
    Write-Warn "No traces within ${WaitForTracesSec}s — SSI may be slow (not a hard failure)"
    return $false
}
Export-ModuleMember -Function Invoke-TraceCheck

# ---------------------------------------------------------------------------
# Save-Results — finalises $results, writes results.json, prints summary.
#   Returns $true if overall_pass, $false otherwise.
# ---------------------------------------------------------------------------

function Save-Results {
    param(
        [hashtable]$Results,
        [string]   $AppName,
        [datetime] $ScriptStart
    )
    $elapsed = [math]::Round(((Get-Date) - $ScriptStart).TotalSeconds)

    $allPass = $true
    foreach ($k in $Results.checks.Keys) {
        if ($Results.checks[$k] -is [hashtable] -or $Results.checks[$k] -is [System.Collections.Specialized.OrderedDictionary]) {
            if ($Results.checks[$k].ContainsKey("pass") -and -not $Results.checks[$k].pass) {
                $allPass = $false
            }
        } elseif ($Results.checks[$k] -is [bool] -and -not $Results.checks[$k]) {
            $allPass = $false
        }
    }
    $Results.overall_pass = $allPass
    $Results.elapsed_sec  = $elapsed
    $Results.app          = $AppName

    $json = $Results | ConvertTo-Json -Depth 6
    Write-Host ""
    Write-Host "── SUMMARY ──────────────────────────────────────────────" -ForegroundColor Cyan
    Write-Output $json
    $json | Out-File -FilePath (Join-Path (Get-Location) "results.json") -Encoding utf8 -Force
    Write-Host "Results written to: $(Join-Path (Get-Location) 'results.json')" -ForegroundColor DarkGray
    Write-Host ""

    if ($allPass) {
        Write-Host "  ALL CHECKS PASSED  ($AppName, ${elapsed}s)" -ForegroundColor Green
    } else {
        Write-Host "  ONE OR MORE CHECKS FAILED  ($AppName, ${elapsed}s)" -ForegroundColor Red
    }
    return $allPass
}
Export-ModuleMember -Function Save-Results
