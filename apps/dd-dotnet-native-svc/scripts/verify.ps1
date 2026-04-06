<#
.SYNOPSIS
    Verifies the DDWorkerSvc Windows Service is healthy and (optionally) sending traces.

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

$ServiceName = "DDWorkerSvc"
$RegEnvPath  = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName\Environment"

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
# Check 1: Health endpoint on port 8084
# ---------------------------------------------------------------------------
$healthUri = "http://${TargetHost}:8084/health"
$resp = Invoke-WithRetry -Uri $healthUri
if ($resp -and $resp.StatusCode -eq 200) {
    try {
        $body = $resp.Content | ConvertFrom-Json
        $pass = ($body.status -eq "ok") -and ($body.service -eq "dd-worker-svc")
    } catch { $pass = $false }
} else { $pass = $false }
$results.checks["health"] = @{ uri = $healthUri; pass = $pass; status_code = $resp?.StatusCode }

# ---------------------------------------------------------------------------
# Check 2: Windows Service running
# ---------------------------------------------------------------------------
try {
    $svc     = Get-Service -Name $ServiceName -ErrorAction Stop
    $svcPass = ($svc.Status -eq "Running")
} catch { $svcPass = $false }
$results.checks["service_running"] = @{ service = $ServiceName; pass = $svcPass }

# ---------------------------------------------------------------------------
# Check 3: Registry env vars present
# ---------------------------------------------------------------------------
try {
    $regVals = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName" `
                                -Name "Environment" -ErrorAction Stop
    $envArr  = $regVals.Environment
    $hasSvc  = ($envArr | Where-Object { $_ -like "DD_SERVICE=*" }).Count -gt 0
    $hasEnv  = ($envArr | Where-Object { $_ -like "DD_ENV=*"     }).Count -gt 0
    $hasVer  = ($envArr | Where-Object { $_ -like "DD_VERSION=*" }).Count -gt 0
    $regPass = $hasSvc -and $hasEnv -and $hasVer
} catch { $regPass = $false }
$results.checks["registry_env_vars"] = @{ path = $RegEnvPath; pass = $regPass }

# ---------------------------------------------------------------------------
# Check 4: Trace check (optional)
# ---------------------------------------------------------------------------
if ($DDApiKey) {
    Write-Host "Waiting up to ${WaitForTracesSec}s for traces from dd-worker-svc..."
    $tracePass = $false
    $deadline  = (Get-Date).AddSeconds($WaitForTracesSec)
    $headers   = @{ "DD-API-KEY" = $DDApiKey; "DD-APPLICATION-KEY" = $DDApiKey }
    $ddApiBase = "https://api.${DDSite}/api/v1"

    while ((Get-Date) -lt $deadline -and -not $tracePass) {
        try {
            $from = [int](Get-Date).AddMinutes(-5).ToUniversalTime().Subtract([datetime]"1970-01-01").TotalSeconds
            $to   = [int](Get-Date).ToUniversalTime().Subtract([datetime]"1970-01-01").TotalSeconds
            $uri  = "${ddApiBase}/query?query=service:dd-worker-svc&from=${from}&to=${to}"
            $tr   = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -UseBasicParsing
            if ($tr.series.Count -gt 0) { $tracePass = $true }
        } catch {}
        if (-not $tracePass) { Start-Sleep -Seconds 5 }
    }
    $results.checks["traces_received"] = @{ service = "dd-worker-svc"; pass = $tracePass }
}

# ---------------------------------------------------------------------------
# Overall
# ---------------------------------------------------------------------------
$allPass = $true
foreach ($k in $results.checks.Keys) {
    if (-not $results.checks[$k].pass) { $allPass = $false }
}
$results.overall_pass = $allPass

Write-Output ($results | ConvertTo-Json -Depth 5)
if ($allPass) { exit 0 } else { exit 1 }
