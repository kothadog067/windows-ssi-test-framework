<#
.SYNOPSIS
    Verifies the dd-dotnet-iis application is healthy and (optionally) sending traces.

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
    [string]$TargetHost      = "localhost",
    [string]$DDApiKey        = "",
    [string]$DDSite          = "datadoghq.com",
    [int]   $WaitForTracesSec = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "SilentlyContinue"

$results = [ordered]@{
    timestamp       = (Get-Date -Format "o")
    target_host     = $TargetHost
    checks          = [ordered]@{}
    overall_pass    = $false
}

# ---------------------------------------------------------------------------
# Helper: HTTP GET with retry
# ---------------------------------------------------------------------------
function Invoke-WithRetry {
    param(
        [string]$Uri,
        [int]   $MaxAttempts = 10,
        [int]   $DelayMs     = 3000
    )
    for ($i = 1; $i -le $MaxAttempts; $i++) {
        try {
            $r = Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 5
            return $r
        } catch {
            if ($i -lt $MaxAttempts) { Start-Sleep -Milliseconds $DelayMs }
        }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Check 1: Health endpoint on port 80
# ---------------------------------------------------------------------------
$healthUri = "http://${TargetHost}:80/health"
$resp = Invoke-WithRetry -Uri $healthUri
if ($resp -and $resp.StatusCode -eq 200) {
    try {
        $body = $resp.Content | ConvertFrom-Json
        $pass = ($body.status -eq "ok") -and ($body.service -eq "dotnet-iis-app")
    } catch { $pass = $false }
} else { $pass = $false }
$results.checks["health_port80"] = @{ uri = $healthUri; pass = $pass; status_code = $resp?.StatusCode }

# ---------------------------------------------------------------------------
# Check 2: Health endpoint on port 8082
# ---------------------------------------------------------------------------
$healthUri2 = "http://${TargetHost}:8082/health"
$resp2 = Invoke-WithRetry -Uri $healthUri2
if ($resp2 -and $resp2.StatusCode -eq 200) {
    try {
        $body2 = $resp2.Content | ConvertFrom-Json
        $pass2 = ($body2.status -eq "ok")
    } catch { $pass2 = $false }
} else { $pass2 = $false }
$results.checks["health_port8082"] = @{ uri = $healthUri2; pass = $pass2; status_code = $resp2?.StatusCode }

# ---------------------------------------------------------------------------
# Check 3: Echo endpoint
# ---------------------------------------------------------------------------
$echoUri  = "http://${TargetHost}:80/echo?msg=verify"
$respEcho = Invoke-WithRetry -Uri $echoUri -MaxAttempts 3
if ($respEcho -and $respEcho.StatusCode -eq 200) {
    try {
        $echoBody = $respEcho.Content | ConvertFrom-Json
        $passEcho = ($echoBody.echo -eq "verify")
    } catch { $passEcho = $false }
} else { $passEcho = $false }
$results.checks["echo_endpoint"] = @{ uri = $echoUri; pass = $passEcho }

# ---------------------------------------------------------------------------
# Check 4: IIS site status
# ---------------------------------------------------------------------------
try {
    Import-Module WebAdministration -ErrorAction Stop
    $site = Get-WebSite -Name "DDIisSite"
    $iisPass = ($site -ne $null) -and ($site.State -eq "Started")
} catch { $iisPass = $false }
$results.checks["iis_site_started"] = @{ site = "DDIisSite"; pass = $iisPass }

# ---------------------------------------------------------------------------
# Check 5: App pool status
# ---------------------------------------------------------------------------
try {
    $pool = Get-WebAppPoolState -Name "DDIisAppPool"
    $poolPass = ($pool.Value -eq "Started")
} catch { $poolPass = $false }
$results.checks["app_pool_started"] = @{ pool = "DDIisAppPool"; pass = $poolPass }

# ---------------------------------------------------------------------------
# Check 6: Trace check (optional — only if API key provided)
# ---------------------------------------------------------------------------
if ($DDApiKey) {
    Write-Host "Waiting up to ${WaitForTracesSec}s for traces from dd-iis-app..."
    $tracePass  = $false
    $deadline   = (Get-Date).AddSeconds($WaitForTracesSec)
    $searchSvc  = "dd-iis-app"
    $ddApiBase  = "https://api.${DDSite}/api/v1"
    $headers    = @{ "DD-API-KEY" = $DDApiKey; "DD-APPLICATION-KEY" = $DDApiKey }

    while ((Get-Date) -lt $deadline -and -not $tracePass) {
        try {
            $from  = [int](Get-Date).AddMinutes(-5).ToUniversalTime().Subtract([datetime]"1970-01-01").TotalSeconds
            $to    = [int](Get-Date).ToUniversalTime().Subtract([datetime]"1970-01-01").TotalSeconds
            $query = "service:$searchSvc"
            $uri   = "${ddApiBase}/query?query=${query}&from=${from}&to=${to}"
            $tr    = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -UseBasicParsing
            if ($tr.series.Count -gt 0) { $tracePass = $true }
        } catch {}
        if (-not $tracePass) { Start-Sleep -Seconds 5 }
    }
    $results.checks["traces_received"] = @{ service = $searchSvc; pass = $tracePass }
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

if ($allPass) { exit 0 } else { exit 1 }
