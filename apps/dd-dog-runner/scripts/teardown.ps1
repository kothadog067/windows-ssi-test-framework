# =============================================================================
#  DD Dog Runner — Teardown Script
#  Stops and removes all Windows Services and cleans up app files.
#  Standard interface: teardown.ps1
#  Exit 0 = success
#  Run as Administrator
# =============================================================================

$ErrorActionPreference = "Continue"

function Log($m) { Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $m" -ForegroundColor Cyan }
function OK($m)  { Write-Host "  [OK] $m" -ForegroundColor Green }

Log "=== DD Dog Runner — Teardown ==="

# ── Stop and remove Windows services ─────────────────────────────────────────
foreach ($svc in @("DDGameServer","DDLeaderboard")) {
    if (Get-Service -Name $svc -ErrorAction SilentlyContinue) {
        Log "Stopping $svc..."
        Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
        if (Get-Command nssm -ErrorAction SilentlyContinue) {
            nssm remove $svc confirm
        } else {
            sc.exe delete $svc | Out-Null
        }
        OK "$svc removed"
    } else {
        OK "$svc was not installed"
    }
}

# ── Remove firewall rules ─────────────────────────────────────────────────────
Log "Removing firewall rules..."
netsh advfirewall firewall delete rule name="DD Game Server 8080"  | Out-Null
netsh advfirewall firewall delete rule name="DD Leaderboard 8081"  | Out-Null
netsh advfirewall firewall delete rule name="DD Demo Game Server"  | Out-Null
netsh advfirewall firewall delete rule name="DD Demo Leaderboard"  | Out-Null
OK "Firewall rules removed"

# ── Clean up app files ────────────────────────────────────────────────────────
$appRoot = "C:\dd-demo"
if (Test-Path $appRoot) {
    Log "Removing $appRoot..."
    Remove-Item -Recurse -Force $appRoot
    OK "$appRoot removed"
} else {
    OK "$appRoot was not present"
}

Write-Host ""
Write-Host "  TEARDOWN COMPLETE: dd-dog-runner" -ForegroundColor Green
exit 0
