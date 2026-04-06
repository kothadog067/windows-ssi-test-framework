# =============================================================================
#  DD Dog Runner — Verify Script
#  Checks health endpoints and (optionally) DD APM trace presence.
#  Standard interface: verify.ps1 [-Host <ip>] [-DDApiKey <key>] [-DDSite <site>]
#  Exit 0 = all checks pass, Exit 1 = one or more checks failed
# =============================================================================

param(
    [string]$TargetHost = "localhost",
    [string]$DDApiKey   = $env:DD_API_KEY,
    [string]$DDSite     = $(if ($env:DD_SITE) { $env:DD_SITE } else { "datadoghq.com" }),
    [int]$TimeoutSec    = 30
)

$ErrorActionPreference = "Continue"
$failed = 0

function Check($label, $url, $expectField, $expectValue) {
    try {
        $resp = Invoke-WebRequest -Uri $url -TimeoutSec $TimeoutSec -UseBasicParsing
        $body = $resp.Content | ConvertFrom-Json
        if ($expectField -and $body.$expectField -ne $expectValue) {
            Write-Host "  [FAIL] $label — $expectField = $($body.$expectField) (expected $expectValue)" -ForegroundColor Red
            $script:failed++
        } else {
            Write-Host "  [OK]   $label" -ForegroundColor Green
        }
    } catch {
        Write-Host "  [FAIL] $label — $_" -ForegroundColor Red
        $script:failed++
    }
}

Write-Host "[$(Get-Date -Format 'HH:mm:ss')] === Verifying dd-dog-runner on $TargetHost ===" -ForegroundColor Cyan

# ── Service health checks ─────────────────────────────────────────────────────
Check ".NET game server health"     "http://${TargetHost}:8080/health" "status" "ok"
Check "Java leaderboard health"     "http://${TargetHost}:8081/health" "status" "ok"
Check "Leaderboard endpoint (GET)"  "http://${TargetHost}:8081/leaderboard" $null $null

# ── Windows service status ────────────────────────────────────────────────────
foreach ($svc in @("DDGameServer", "DDLeaderboard")) {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if ($s -and $s.Status -eq "Running") {
        Write-Host "  [OK]   Windows service $svc RUNNING" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] Windows service $svc not running (status: $($s.Status))" -ForegroundColor Red
        $failed++
    }
}

# ── DD APM trace check (optional — needs API key + some wait time) ────────────
if ($DDApiKey) {
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Checking Datadog APM for traces..." -ForegroundColor Cyan
    $services = @("dd-game-server", "dd-leaderboard")
    foreach ($svcName in $services) {
        try {
            $uri = "https://api.$DDSite/api/v1/services/dependencies?env=demo&service=$svcName&start=$(([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 300))"
            $headers = @{ "DD-API-KEY" = $DDApiKey }
            $r = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 15
            if ($r) {
                Write-Host "  [OK]   APM: $svcName visible in Datadog" -ForegroundColor Green
            } else {
                Write-Host "  [WARN] APM: $svcName not yet visible (may need more time)" -ForegroundColor Yellow
            }
        } catch {
            Write-Host "  [WARN] APM check for $svcName failed: $_" -ForegroundColor Yellow
        }
    }
}

Write-Host ""
if ($failed -eq 0) {
    Write-Host "  ALL CHECKS PASSED" -ForegroundColor Green
    exit 0
} else {
    Write-Host "  $failed CHECK(S) FAILED" -ForegroundColor Red
    exit 1
}
