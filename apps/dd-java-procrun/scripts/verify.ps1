<#
.SYNOPSIS
    Verifies the dd-java-procrun service is healthy and (optionally) sending traces.

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
# Check 4: Trace check (optional)
# ---------------------------------------------------------------------------
if ($DDApiKey) {
    Write-Host "Waiting up to ${WaitForTracesSec}s for traces from java-procrun-app..."
    $tracePass = $false
    $deadline  = (Get-Date).AddSeconds($WaitForTracesSec)
    $headers   = @{ "DD-API-KEY" = $DDApiKey; "DD-APPLICATION-KEY" = $DDApiKey }
    $ddApiBase = "https://api.${DDSite}/api/v1"

    while ((Get-Date) -lt $deadline -and -not $tracePass) {
        try {
            $from  = [int](Get-Date).AddMinutes(-5).ToUniversalTime().Subtract([datetime]"1970-01-01").TotalSeconds
            $to    = [int](Get-Date).ToUniversalTime().Subtract([datetime]"1970-01-01").TotalSeconds
            $uri   = "${ddApiBase}/query?query=service:java-procrun-app&from=${from}&to=${to}"
            $tr    = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -UseBasicParsing
            if ($tr.series.Count -gt 0) { $tracePass = $true }
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

Write-Output ($results | ConvertTo-Json -Depth 5)
if ($allPass) { exit 0 } else { exit 1 }
