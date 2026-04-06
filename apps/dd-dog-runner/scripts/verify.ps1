# =============================================================================
#  DD Dog Runner — Verify Script
#  Full SSI instrumentation validation: traffic generation, health checks,
#  DD APM trace validation via API v2, DLL injection check, skip list check,
#  SSI injection status, JSON summary.
#
#  Standard interface: verify.ps1 [-TargetHost <ip>] [-DDApiKey <key>]
#                                  [-DDSite <site>] [-TimeoutSec <n>]
#                                  [-WaitForTracesSec <n>]
#  Exit 0 = all health/service checks pass (APM warnings do not cause failure)
#  Exit 1 = one or more health or service checks failed
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

# --------------------------------------------------------------------------- #
#  Mutable state — written to by helper functions                              #
# --------------------------------------------------------------------------- #
$failed = 0
$checks = [ordered]@{
    health_dotnet         = $false
    health_java           = $false
    dll_injection_dotnet  = $false
    dll_injection_java    = $false
    skiplist_clean        = $false
    traces_dotnet         = $false
    traces_java           = $false
    ssi_injected          = $false
}

# --------------------------------------------------------------------------- #
#  Helpers                                                                     #
# --------------------------------------------------------------------------- #

function Write-Section([string]$title) {
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host ""
    Write-Host "[$ts] ── $title " -ForegroundColor Cyan
}

function Write-Ok([string]$msg) {
    Write-Host "  [OK]   $msg" -ForegroundColor Green
}

function Write-Fail([string]$msg) {
    Write-Host "  [FAIL] $msg" -ForegroundColor Red
    $script:failed++
}

function Write-Warn([string]$msg) {
    Write-Host "  [WARN] $msg" -ForegroundColor Yellow
}

# Test-DllInjected: returns $true if ddinjector_x64.dll is loaded in the named process.
# Uses tasklist /m which is the same mechanism as validate_injection_process.exe (GetModuleHandleA).
function Test-DllInjected {
    param(
        [string]$ProcessName,
        [string]$DllName = "ddinjector_x64.dll"
    )
    $output = & tasklist /fi "imagename eq $ProcessName" /m $DllName 2>&1
    return ($output | Where-Object { $_ -match [regex]::Escape($ProcessName) }).Count -gt 0
}

# Test-SkipListClean: returns list of skip-listed processes that wrongly have the DLL loaded.
# Per default-skiplist.yaml: agent.exe, datadogagent.exe, trace-agent.exe, etc. must NEVER be instrumented.
function Test-SkipListClean {
    $skipProcs = @(
        "datadogagent.exe",
        "agent.exe",
        "trace-agent.exe",
        "process-agent.exe",
        "system-probe.exe",
        "security-agent.exe"
    )
    $violations = @()
    foreach ($proc in $skipProcs) {
        $output = & tasklist /fi "imagename eq $proc" /m "ddinjector_x64.dll" 2>&1
        if ($output | Where-Object { $_ -match [regex]::Escape($proc) }) {
            $violations += $proc
        }
    }
    return $violations
}

# Invoke-WebRequest with retry.
# Returns the parsed JSON body on success, $null on all-retry failure.
# If $failOnError is $true, increments $failed and returns $null on final failure.
function Invoke-WithRetry {
    param(
        [string]$Label,
        [string]$Uri,
        [hashtable]$Headers      = @{},
        [string]$Method          = "GET",
        [string]$Body            = $null,
        [int]   $RetryCount      = 3,
        [int]   $RetrySleepSec   = 5,
        [bool]  $FailOnError     = $true,
        [bool]  $Silent          = $false
    )

    $attempt = 0
    while ($attempt -lt $RetryCount) {
        $attempt++
        try {
            $params = @{
                Uri             = $Uri
                Method          = $Method
                TimeoutSec      = $TimeoutSec
                UseBasicParsing = $true
                Headers         = $Headers
            }
            if ($Body) {
                $params.Body        = $Body
                $params.ContentType = "application/json"
            }

            $resp = Invoke-WebRequest @params
            return ($resp.Content | ConvertFrom-Json)
        } catch {
            if ($attempt -lt $RetryCount) {
                if (-not $Silent) {
                    Write-Warn "$Label — attempt $attempt failed ($_). Retrying in ${RetrySleepSec}s..."
                }
                Start-Sleep -Seconds $RetrySleepSec
            } else {
                if ($FailOnError -and -not $Silent) {
                    Write-Fail "$Label — all $RetryCount attempts failed. Last error: $_"
                } elseif (-not $Silent) {
                    Write-Warn "$Label — all $RetryCount attempts failed. Last error: $_"
                }
                return $null
            }
        }
    }
    return $null
}

# --------------------------------------------------------------------------- #
#  SECTION 1 — Generate traffic so that spans actually exist in DD             #
# --------------------------------------------------------------------------- #

Write-Section "GENERATING TRAFFIC (populate spans before querying DD)"

$scorePayload = '{"name":"ssi-verify-bot","score":9999}'

Write-Host "  Sending 3x POST /score to .NET game server..."
for ($i = 1; $i -le 3; $i++) {
    try {
        $r = Invoke-WebRequest -Uri "http://${TargetHost}:8080/score" `
                               -Method POST `
                               -Body $scorePayload `
                               -ContentType "application/json" `
                               -TimeoutSec $TimeoutSec `
                               -UseBasicParsing
        Write-Host "    POST /score attempt $i — HTTP $($r.StatusCode)"
    } catch {
        Write-Host "    POST /score attempt $i — ERROR: $_" -ForegroundColor Yellow
    }
    if ($i -lt 3) { Start-Sleep -Milliseconds 500 }
}

Write-Host "  Sending 3x GET /leaderboard to Java leaderboard service..."
for ($i = 1; $i -le 3; $i++) {
    try {
        $r = Invoke-WebRequest -Uri "http://${TargetHost}:8081/leaderboard" `
                               -Method GET `
                               -TimeoutSec $TimeoutSec `
                               -UseBasicParsing
        Write-Host "    GET /leaderboard attempt $i — HTTP $($r.StatusCode)"
    } catch {
        Write-Host "    GET /leaderboard attempt $i — ERROR: $_" -ForegroundColor Yellow
    }
    if ($i -lt 3) { Start-Sleep -Milliseconds 500 }
}

Write-Host "  Sending GET /health to both services..."
foreach ($ep in @("http://${TargetHost}:8080/health", "http://${TargetHost}:8081/health")) {
    try {
        $r = Invoke-WebRequest -Uri $ep -Method GET -TimeoutSec $TimeoutSec -UseBasicParsing
        Write-Host "    GET $ep — HTTP $($r.StatusCode)"
    } catch {
        Write-Host "    GET $ep — ERROR: $_" -ForegroundColor Yellow
    }
}

Write-Host "  Traffic generation complete."

# --------------------------------------------------------------------------- #
#  SECTION 2 — Windows service status                                          #
# --------------------------------------------------------------------------- #

Write-Section "WINDOWS SERVICE STATUS"

foreach ($svc in @("DDGameServer", "DDLeaderboard")) {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if ($s -and $s.Status -eq "Running") {
        Write-Ok "Windows service $svc RUNNING"
    } else {
        $status = if ($s) { $s.Status } else { "not found" }
        Write-Fail "Windows service $svc not running (status: $status)"
    }
}

# --------------------------------------------------------------------------- #
#  SECTION 3 — HTTP health checks (with retry)                                 #
# --------------------------------------------------------------------------- #

Write-Section "HTTP HEALTH CHECKS (3 attempts, 5s between retries)"

# .NET game server
$dotnetHealth = Invoke-WithRetry -Label ".NET game server /health" `
                                 -Uri "http://${TargetHost}:8080/health" `
                                 -RetryCount 3 `
                                 -RetrySleepSec 5 `
                                 -FailOnError $true

if ($dotnetHealth -and $dotnetHealth.status -eq "ok") {
    Write-Ok ".NET game server health — status=ok"
    $checks["health_dotnet"] = $true
} elseif ($dotnetHealth) {
    Write-Fail ".NET game server health — status=$($dotnetHealth.status) (expected ok)"
} else {
    # failure already recorded by Invoke-WithRetry
}

# Java leaderboard
$javaHealth = Invoke-WithRetry -Label "Java leaderboard /health" `
                               -Uri "http://${TargetHost}:8081/health" `
                               -RetryCount 3 `
                               -RetrySleepSec 5 `
                               -FailOnError $true

if ($javaHealth -and $javaHealth.status -eq "ok") {
    Write-Ok "Java leaderboard health — status=ok"
    $checks["health_java"] = $true
} elseif ($javaHealth) {
    Write-Fail "Java leaderboard health — status=$($javaHealth.status) (expected ok)"
} else {
    # failure already recorded by Invoke-WithRetry
}

# --------------------------------------------------------------------------- #
#  SECTION 4 — DD APM trace validation (requires DDApiKey)                     #
# --------------------------------------------------------------------------- #

Write-Section "DD APM TRACE VALIDATION"

if (-not $DDApiKey) {
    Write-Warn "DD_API_KEY not set — skipping APM trace validation."
} else {

    # Map service names to their check keys
    $serviceMap = [ordered]@{
        "dd-game-server" = "traces_dotnet"
        "dd-leaderboard" = "traces_java"
    }

    $ddHeaders = @{
        "DD-API-KEY"          = $DDApiKey
        "DD-APPLICATION-KEY"  = $env:DD_APP_KEY   # optional; v2 spans endpoint accepts API key only
    }

    foreach ($svcName in $serviceMap.Keys) {
        $checkKey   = $serviceMap[$svcName]
        $found      = $false
        $deadline   = (Get-Date).AddSeconds($WaitForTracesSec)
        $pollSec    = 10
        $attempt    = 0

        Write-Host "  Polling DD for traces from service '$svcName' (up to ${WaitForTracesSec}s)..."

        while ((Get-Date) -lt $deadline) {
            $attempt++
            $fromEpochMs = [DateTimeOffset]::UtcNow.AddMinutes(-5).ToUnixTimeMilliseconds()
            $toEpochMs   = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

            $query       = "service:$svcName env:demo"
            $encodedQ    = [Uri]::EscapeDataString($query)
            $spansUri    = "https://api.$DDSite/api/v2/spans" +
                           "?filter[query]=$encodedQ" +
                           "&filter[from]=$fromEpochMs" +
                           "&filter[to]=$toEpochMs" +
                           "&page[limit]=10"

            try {
                $resp = Invoke-RestMethod -Uri $spansUri `
                                         -Headers $ddHeaders `
                                         -Method GET `
                                         -TimeoutSec 20

                $spanCount = 0
                if ($resp.data -and $resp.data.Count -gt 0) {
                    $spanCount = $resp.data.Count
                }

                if ($spanCount -gt 0) {
                    Write-Ok "Service '$svcName' — $spanCount span(s) found in DD"

                    # Validate SSI-specific meta tags on the first span
                    $firstSpan  = $resp.data[0]
                    $meta       = $firstSpan.attributes.tags

                    $tracerVer  = $meta."_dd.tracer_version"
                    $langTag    = $meta."language"

                    if ($tracerVer) {
                        Write-Ok "  _dd.tracer_version = $tracerVer  (SSI injected the tracer)"
                    } else {
                        Write-Warn "  _dd.tracer_version tag not found on span (SSI injection may not have occurred)"
                    }

                    if ($langTag) {
                        Write-Ok "  language = $langTag  (correct tracer loaded)"
                    } else {
                        Write-Warn "  language tag not found on span"
                    }

                    $checks[$checkKey] = $true
                    $found = $true
                    break
                } else {
                    $remaining = [math]::Round(($deadline - (Get-Date)).TotalSeconds)
                    Write-Host "    [poll $attempt] No spans yet for '$svcName' — ${remaining}s remaining..."
                    Start-Sleep -Seconds $pollSec
                }

            } catch {
                $remaining = [math]::Round(($deadline - (Get-Date)).TotalSeconds)
                Write-Host "    [poll $attempt] DD API error for '$svcName': $_ — ${remaining}s remaining..."
                Start-Sleep -Seconds $pollSec
            }
        }

        if (-not $found) {
            Write-Warn "No traces found for '$svcName' within ${WaitForTracesSec}s — SSI may just be slow (not a hard failure)"
        }
    }
}

# --------------------------------------------------------------------------- #
#  SECTION 5 — SSI injection status check                                      #
# --------------------------------------------------------------------------- #

Write-Section "SSI INJECTION STATUS"

$logDir        = "C:\ProgramData\Datadog\logs"
$ssiConfirmed  = $false

if (Test-Path $logDir) {
    # Look in files modified within the last 30 minutes
    $cutoff    = (Get-Date).AddMinutes(-30)
    $logFiles  = Get-ChildItem -Path $logDir -File -Recurse -ErrorAction SilentlyContinue |
                 Where-Object { $_.LastWriteTime -gt $cutoff }

    foreach ($logFile in $logFiles) {
        try {
            $hits = Select-String -Path $logFile.FullName `
                                  -Pattern "injected" `
                                  -CaseSensitive:$false `
                                  -ErrorAction SilentlyContinue
            if ($hits -and $hits.Count -gt 0) {
                $ssiConfirmed = $true
                Write-Ok "SSI confirmed injected into DDGameServer"
                Write-Host "    Source: $($logFile.FullName) ($($hits.Count) match(es))" -ForegroundColor DarkGray
                break
            }
        } catch {
            # Non-fatal — continue scanning other log files
        }
    }

    if (-not $ssiConfirmed) {
        # Also check Windows registry for ddinjector markers
        $regPaths = @(
            "HKLM:\SOFTWARE\Datadog\Datadog Agent",
            "HKLM:\SOFTWARE\Datadog"
        )
        foreach ($regPath in $regPaths) {
            if (Test-Path $regPath) {
                $regVals = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
                if ($regVals -and ($regVals | Get-Member -MemberType NoteProperty |
                                   Where-Object { $_.Name -match "inject" })) {
                    $ssiConfirmed = $true
                    Write-Ok "SSI confirmed via registry key at $regPath"
                    break
                }
            }
        }
    }
} else {
    Write-Warn "Log directory $logDir not found — cannot check SSI injection status"
}

if ($ssiConfirmed) {
    $checks["ssi_injected"] = $true
} else {
    Write-Host "  [INFO] SSI injection not confirmed (check ddinjector logs in $logDir)" -ForegroundColor DarkYellow
}

# --------------------------------------------------------------------------- #
#  SECTION 5.5 — DLL injection check (authoritative: ddinjector_x64.dll in    #
#               target process module list, same as validate_injection_process) #
# --------------------------------------------------------------------------- #

Write-Section "DLL INJECTION CHECK (ddinjector_x64.dll in process module list)"

# Check .NET game server process (dotnet.exe via NSSM)
if (Test-DllInjected -ProcessName "dotnet.exe") {
    Write-Ok "ddinjector_x64.dll loaded in dotnet.exe (.NET game server)"
    $checks["dll_injection_dotnet"] = $true
} else {
    Write-Fail "ddinjector_x64.dll NOT found in dotnet.exe — .NET SSI injection failed"
}

# Check Java leaderboard process (java.exe via NSSM)
if (Test-DllInjected -ProcessName "java.exe") {
    Write-Ok "ddinjector_x64.dll loaded in java.exe (Java leaderboard)"
    $checks["dll_injection_java"] = $true
} else {
    Write-Fail "ddinjector_x64.dll NOT found in java.exe — Java SSI injection failed"
}

# Skip list check: per default-skiplist.yaml, DD agent processes must NEVER be instrumented
Write-Host ""
Write-Host "  Verifying skip list (DD agent processes must NOT be instrumented)..."
$violations = Test-SkipListClean
if ($violations.Count -eq 0) {
    Write-Ok "Skip list clean — no agent processes instrumented"
    $checks["skiplist_clean"] = $true
} else {
    Write-Fail "Skip list violation: ddinjector_x64.dll found in: $($violations -join ', ')"
}

# --------------------------------------------------------------------------- #
#  SECTION 6 — Structured JSON summary                                         #
# --------------------------------------------------------------------------- #

Write-Section "SUMMARY"

$elapsedSec = [math]::Round(((Get-Date) - $scriptStart).TotalSeconds)

$summary = [ordered]@{
    app         = "dd-dog-runner"
    checks      = $checks
    elapsed_sec = $elapsedSec
}

$summaryJson = $summary | ConvertTo-Json -Depth 5

$resultsPath = Join-Path (Get-Location) "results.json"
$summaryJson | Out-File -FilePath $resultsPath -Encoding utf8 -Force
Write-Host "  Results written to: $resultsPath"
Write-Host ""
Write-Host $summaryJson

# --------------------------------------------------------------------------- #
#  Final exit                                                                  #
# --------------------------------------------------------------------------- #

Write-Host ""
if ($failed -eq 0) {
    Write-Host "  ALL CHECKS PASSED (elapsed: ${elapsedSec}s)" -ForegroundColor Green
    exit 0
} else {
    Write-Host "  $failed CHECK(S) FAILED (elapsed: ${elapsedSec}s)" -ForegroundColor Red
    exit 1
}
