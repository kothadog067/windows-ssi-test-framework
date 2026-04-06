<#
.SYNOPSIS
    Verifies the dd-java-procrun service is healthy and (optionally) sending traces.
    Also checks ddinjector_x64.dll is loaded in prunsrv.exe (Apache Procrun SSI injection)
    and that skip-listed Datadog agent processes are NOT instrumented.

.PARAMETER TargetHost
    Hostname or IP to check. Defaults to localhost.

.PARAMETER DDApiKey
    Datadog API key for trace verification (optional).

.PARAMETER DDSite
    Datadog site for trace verification (optional).

.PARAMETER WaitForTracesSec
    How many seconds to wait while polling for traces. Defaults to 30.

.OUTPUTS
    Writes a JSON result object to stdout and exits 0 (pass) or 1 (fail).
#>
[CmdletBinding()]
param(
    [string]$TargetHost       = "localhost",
    [string]$DDApiKey         = "",
    [string]$DDSite           = "datadoghq.com",
    [int]   $WaitForTracesSec = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "SilentlyContinue"

$ServiceName = "JavaProcrunSvc"

$results = [ordered]@{
    timestamp    = (Get-Date -Format "o")
    target_host  = $TargetHost
    checks       = [ordered]@{}
    overall_pass = $false
}

function Invoke-WithRetry {
    param([string]$Uri, [int]$MaxAttempts = 10, [int]$DelayMs = 3000)
    for ($i = 1; $i -le $MaxAttempts; $i++) {
        try {
            return Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 5
        } catch {
            if ($i -lt $MaxAttempts) { Start-Sleep -Milliseconds $DelayMs }
        }
    }
    return $null
}

# DLL injection check — same mechanism as validate_injection_process.exe (GetModuleHandleA)
function Test-DllInjected {
    param(
        [string]$ProcessName,
        [string]$DllName = "ddinjector_x64.dll"
    )
    $output = & tasklist /fi "imagename eq $ProcessName" /m $DllName 2>&1
    return ($output | Where-Object { $_ -match [regex]::Escape($ProcessName) }).Count -gt 0
}

# Skip list check — per default-skiplist.yaml, DD agent processes must never be instrumented
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

# ---------------------------------------------------------------------------
# Check 1: Health endpoint
# ---------------------------------------------------------------------------
$healthUri = "http://${TargetHost}:8083/health"
$resp = Invoke-WithRetry -Uri $healthUri
if ($resp -and $resp.StatusCode -eq 200) {
    try {
        $body = $resp.Content | ConvertFrom-Json
        $pass = ($body.status -eq "ok") -and ($body.service -eq "java-procrun-app")
    } catch { $pass = $false }
} else { $pass = $false }
$results.checks["health"] = @{ uri = $healthUri; pass = $pass; status_code = $resp?.StatusCode }

# ---------------------------------------------------------------------------
# Check 2: Ping endpoint
# ---------------------------------------------------------------------------
$pingUri  = "http://${TargetHost}:8083/ping"
$respPing = Invoke-WithRetry -Uri $pingUri -MaxAttempts 3
if ($respPing -and $respPing.StatusCode -eq 200) {
    try {
        $pingBody = $respPing.Content | ConvertFrom-Json
        $passPing = ($pingBody.pong -eq $true)
    } catch { $passPing = $false }
} else { $passPing = $false }
$results.checks["ping"] = @{ uri = $pingUri; pass = $passPing }

# ---------------------------------------------------------------------------
# Check 3: Windows Service status
# ---------------------------------------------------------------------------
try {
    $svc     = Get-Service -Name $ServiceName -ErrorAction Stop
    $svcPass = ($svc.Status -eq "Running")
} catch { $svcPass = $false }
$results.checks["service_running"] = @{ service = $ServiceName; pass = $svcPass }

# ---------------------------------------------------------------------------
# Check 4: DLL injection — ddinjector_x64.dll must be loaded in prunsrv.exe
# prunsrv.exe is the Apache Commons Daemon process; explicitly detected by
# java.c in the ddinjector source (is_procrun_service).
# ---------------------------------------------------------------------------
$dllInjectPass = Test-DllInjected -ProcessName "prunsrv.exe"
$results.checks["dll_injection_prunsrv"] = @{
    process = "prunsrv.exe"
    dll     = "ddinjector_x64.dll"
    pass    = $dllInjectPass
}
if ($dllInjectPass) {
    Write-Host "  [OK]   ddinjector_x64.dll loaded in prunsrv.exe (Procrun SSI injection confirmed)" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] ddinjector_x64.dll NOT found in prunsrv.exe — Procrun SSI injection failed" -ForegroundColor Red
}

# ---------------------------------------------------------------------------
# Check 5: Skip list — DD agent processes must NOT be instrumented
# ---------------------------------------------------------------------------
$skipViolations = Test-SkipListClean
$skipPass       = ($skipViolations.Count -eq 0)
$results.checks["skiplist_clean"] = @{
    pass       = $skipPass
    violations = $skipViolations
}
if ($skipPass) {
    Write-Host "  [OK]   Skip list clean — no agent processes instrumented" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] Skip list violation: $($skipViolations -join ', ') has ddinjector_x64.dll loaded" -ForegroundColor Red
}

# ---------------------------------------------------------------------------
# Check 6: Trace check (optional)
# ---------------------------------------------------------------------------
if ($DDApiKey) {
    Write-Host "Waiting up to ${WaitForTracesSec}s for traces from java-procrun-app..."
    $tracePass = $false
    $deadline  = (Get-Date).AddSeconds($WaitForTracesSec)
    $ddHeaders = @{ "DD-API-KEY" = $DDApiKey }

    while ((Get-Date) -lt $deadline -and -not $tracePass) {
        try {
            $fromMs = [DateTimeOffset]::UtcNow.AddMinutes(-5).ToUnixTimeMilliseconds()
            $toMs   = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            $q      = [Uri]::EscapeDataString("service:java-procrun-app")
            $uri    = "https://api.${DDSite}/api/v2/spans?filter[query]=$q&filter[from]=$fromMs&filter[to]=$toMs&page[limit]=5"
            $tr     = Invoke-RestMethod -Uri $uri -Headers $ddHeaders -Method Get -TimeoutSec 15
            if ($tr.data -and $tr.data.Count -gt 0) {
                $tracePass = $true
                $tv = $tr.data[0].attributes.tags."_dd.tracer_version"
                Write-Host "  [OK]   Traces found — _dd.tracer_version=$tv" -ForegroundColor Green
            }
        } catch {}
        if (-not $tracePass) { Start-Sleep -Seconds 5 }
    }
    $results.checks["traces_received"] = @{ service = "java-procrun-app"; pass = $tracePass }
}

# ---------------------------------------------------------------------------
# Overall result
# ---------------------------------------------------------------------------
$allPass = $true
foreach ($k in $results.checks.Keys) {
    if (-not $results.checks[$k].pass) { $allPass = $false }
}
$results.overall_pass = $allPass

$json = $results | ConvertTo-Json -Depth 5
Write-Output $json
$json | Out-File -FilePath (Join-Path (Get-Location) "results.json") -Encoding utf8 -Force

if ($allPass) { exit 0 } else { exit 1 }
