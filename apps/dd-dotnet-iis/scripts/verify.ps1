<#
.SYNOPSIS
    Verifies the dd-dotnet-iis application is healthy and (optionally) sending traces.
    Also checks ddinjector_x64.dll is loaded in w3wp.exe (IIS SSI injection) and
    that skip-listed Datadog agent processes are NOT instrumented.

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
# Helper: DLL injection check — same mechanism as validate_injection_process.exe
# Returns $true if ddinjector_x64.dll is in the process module list
# ---------------------------------------------------------------------------
function Test-DllInjected {
    param(
        [string]$ProcessName,
        [string]$DllName = "ddinjector_x64.dll"
    )
    $output = & tasklist /fi "imagename eq $ProcessName" /m $DllName 2>&1
    return ($output | Where-Object { $_ -match [regex]::Escape($ProcessName) }).Count -gt 0
}

# ---------------------------------------------------------------------------
# Helper: Skip list check — per default-skiplist.yaml, DD agent processes
# must NEVER have ddinjector_x64.dll loaded
# ---------------------------------------------------------------------------
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
# Check 6: DLL injection — ddinjector_x64.dll must be loaded in w3wp.exe
# IIS worker process (w3wp.exe) is the injection target for IIS-hosted apps.
# This is the authoritative check: same as validate_injection_process.exe.
# ---------------------------------------------------------------------------
$dllInjectPass = Test-DllInjected -ProcessName "w3wp.exe"
$results.checks["dll_injection_w3wp"] = @{
    process = "w3wp.exe"
    dll     = "ddinjector_x64.dll"
    pass    = $dllInjectPass
}
if ($dllInjectPass) {
    Write-Host "  [OK]   ddinjector_x64.dll loaded in w3wp.exe (IIS SSI injection confirmed)" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] ddinjector_x64.dll NOT found in w3wp.exe — IIS SSI injection failed" -ForegroundColor Red
}

# ---------------------------------------------------------------------------
# Check 7: Skip list — DD agent processes must NOT be instrumented
# Per default-skiplist.yaml in the ddinjector source
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
# Check 8: Trace check (optional — only if API key provided)
# ---------------------------------------------------------------------------
if ($DDApiKey) {
    Write-Host "Waiting up to ${WaitForTracesSec}s for traces from dd-iis-app..."
    $tracePass  = $false
    $deadline   = (Get-Date).AddSeconds($WaitForTracesSec)
    $searchSvc  = "dd-iis-app"
    $ddHeaders  = @{ "DD-API-KEY" = $DDApiKey }

    while ((Get-Date) -lt $deadline -and -not $tracePass) {
        try {
            $fromMs = [DateTimeOffset]::UtcNow.AddMinutes(-5).ToUnixTimeMilliseconds()
            $toMs   = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            $q      = [Uri]::EscapeDataString("service:$searchSvc")
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
$json | Out-File -FilePath (Join-Path (Get-Location) "results.json") -Encoding utf8 -Force

if ($allPass) { exit 0 } else { exit 1 }
