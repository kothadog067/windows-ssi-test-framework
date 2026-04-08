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

# ── Traffic generation — populate spans before querying Datadog ───────────────
Write-Step "GENERATING TRAFFIC"
$scorePayload = '{"name":"ssi-verify-bot","score":9999}'

Write-Host "  Sending 3x POST /score to .NET game server..." -ForegroundColor DarkGray
for ($i = 1; $i -le 3; $i++) {
    try { Invoke-WithRetry -Uri "http://${TargetHost}:8080/score" -Method POST -Body $scorePayload -MaxAttempts 2 -TimeoutSec 5 | Out-Null } catch {}
    if ($i -lt 3) { Start-Sleep -Milliseconds 500 }
}

Write-Host "  Sending 3x GET /leaderboard to Java leaderboard service..." -ForegroundColor DarkGray
for ($i = 1; $i -le 3; $i++) {
    try { Invoke-WithRetry -Uri "http://${TargetHost}:8081/leaderboard" -MaxAttempts 2 -TimeoutSec 5 | Out-Null } catch {}
    if ($i -lt 3) { Start-Sleep -Milliseconds 500 }
}
Write-Host "  Traffic generation complete." -ForegroundColor DarkGray

# ── Windows service status ────────────────────────────────────────────────────
Write-Step "WINDOWS SERVICE STATUS"
foreach ($svcName in @("DDGameServer", "DDLeaderboard")) {
    $s     = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    $sPass = $s -and $s.Status -eq "Running"
    $results.checks["service_$svcName"] = @{ service = $svcName; pass = $sPass }
    if ($sPass) { Write-OK "$svcName RUNNING" }
    else        { Write-Fail "$svcName not running (status: $(if ($s) { $s.Status } else { 'not found' }))"; $failed++ }
}

# ── Health checks ─────────────────────────────────────────────────────────────
Write-Step "HTTP HEALTH CHECKS"
$dotnetHealth = Invoke-WithRetry -Uri "http://${TargetHost}:8080/health" -TimeoutSec $TimeoutSec
$dotnetPass   = $dotnetHealth -and $dotnetHealth.status -eq "ok"
$results.checks["health_dotnet"] = @{ uri = "http://${TargetHost}:8080/health"; pass = $dotnetPass }
if ($dotnetPass) { Write-OK ".NET game server health OK (port 8080)" }
else             { Write-Fail ".NET game server health FAILED (port 8080)"; $failed++ }

$javaHealth = Invoke-WithRetry -Uri "http://${TargetHost}:8081/health" -TimeoutSec $TimeoutSec
$javaPass   = $javaHealth -and $javaHealth.status -eq "ok"
$results.checks["health_java"] = @{ uri = "http://${TargetHost}:8081/health"; pass = $javaPass }
if ($javaPass) { Write-OK "Java leaderboard health OK (port 8081)" }
else           { Write-Fail "Java leaderboard health FAILED (port 8081)"; $failed++ }

# ── DLL injection ─────────────────────────────────────────────────────────────
Write-Step "DLL INJECTION CHECK"
$dllDotnet = Test-DllInjected -ProcessName "dotnet.exe"
$results.checks["dll_injection_dotnet"] = @{ process = "dotnet.exe"; dll = "ddinjector_x64.dll"; pass = $dllDotnet }
if ($dllDotnet) { Write-OK "ddinjector_x64.dll in dotnet.exe (.NET game server)" }
else            { Write-Fail "ddinjector_x64.dll NOT in dotnet.exe"; $failed++ }

$dllJava = Test-DllInjected -ProcessName "java.exe"
$results.checks["dll_injection_java"] = @{ process = "java.exe"; dll = "ddinjector_x64.dll"; pass = $dllJava }
if ($dllJava) { Write-OK "ddinjector_x64.dll in java.exe (Java leaderboard)" }
else          { Write-Fail "ddinjector_x64.dll NOT in java.exe"; $failed++ }

# ── Skip list ────────────────────────────────────────────────────────────────
$violations = Test-SkipListClean
$skipPass   = ($violations.Count -eq 0)
$results.checks["skiplist_clean"] = @{ pass = $skipPass; violations = $violations }
if ($skipPass) { Write-OK "Skip list clean" } else { Write-Fail "Skip list violation: $($violations -join ', ')"; $failed++ }

# ── SSI injection via Datadog logs (informational) ───────────────────────────
Write-Step "SSI INJECTION LOG CHECK"
$logDir       = "C:\ProgramData\Datadog\logs"
$ssiConfirmed = $false
if (Test-Path $logDir) {
    $cutoff   = (Get-Date).AddMinutes(-30)
    $logFiles = Get-ChildItem -Path $logDir -File -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -gt $cutoff }
    foreach ($logFile in $logFiles) {
        try {
            $hits = Select-String -Path $logFile.FullName -Pattern "injected" -CaseSensitive:$false -ErrorAction SilentlyContinue
            if ($hits -and $hits.Count -gt 0) { $ssiConfirmed = $true; break }
        } catch {}
    }
}
if ($ssiConfirmed) { Write-OK "SSI injection confirmed in Datadog logs" }
else               { Write-Host "  [INFO] SSI injection not confirmed in logs (check $logDir)" -ForegroundColor DarkYellow }
# Informational — no "pass" key; log check supplements the authoritative DLL check above
$results.checks["ssi_log_check"] = @{ confirmed = $ssiConfirmed; log_dir = $logDir }

# ── Traces (informational — not hard failures per original design) ────────────
Write-Step "TRACE CHECK"
if ($DDApiKey) {
    $ddHeaders = @{ "DD-API-KEY" = $DDApiKey }
    foreach ($svcName in @("dd-game-server", "dd-leaderboard")) {
        $found    = $false
        $deadline = (Get-Date).AddSeconds($WaitForTracesSec)
        $attempt  = 0
        Write-Host "  Polling DD for '$svcName' (up to ${WaitForTracesSec}s)..." -ForegroundColor DarkGray

        while ((Get-Date) -lt $deadline) {
            $attempt++
            try {
                $fromMs = [DateTimeOffset]::UtcNow.AddMinutes(-5).ToUnixTimeMilliseconds()
                $toMs   = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                $q      = [Uri]::EscapeDataString("service:$svcName env:demo")
                $uri    = "https://api.$DDSite/api/v2/spans?filter[query]=$q&filter[from]=$fromMs&filter[to]=$toMs&page[limit]=10"
                $tr     = Invoke-RestMethod -Uri $uri -Headers $ddHeaders -Method Get -TimeoutSec 20
                if ($tr.data -and $tr.data.Count -gt 0) {
                    $tv = $tr.data[0].attributes.tags."_dd.tracer_version"
                    $lg = $tr.data[0].attributes.tags."language"
                    Write-OK "Service '$svcName' — $($tr.data.Count) span(s), _dd.tracer_version=$tv, language=$lg"
                    $found = $true; break
                }
            } catch {}
            $rem = [math]::Round(($deadline - (Get-Date)).TotalSeconds)
            Write-Host "    [poll $attempt] No spans for '$svcName' — ${rem}s remaining..." -ForegroundColor DarkGray
            Start-Sleep -Seconds 10
        }
        if (-not $found) { Write-Warn "No traces for '$svcName' within ${WaitForTracesSec}s (not a hard failure)" }
        # Informational — no "pass" key (traces are not hard failures for dd-dog-runner)
        $results.checks["traces_$($svcName -replace '-','_')"] = @{ service = $svcName; found = $found }
    }
} else {
    Write-Warn "DD_API_KEY not set — skipping trace check"
}

$pass = Save-Results -Results $results -AppName "dd-dog-runner" -ScriptStart $scriptStart
if ($pass) { exit 0 } else { exit 1 }
