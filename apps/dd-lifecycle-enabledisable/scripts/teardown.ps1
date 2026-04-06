# =============================================================================
#  dd-lifecycle-enabledisable — Teardown Script. Exit 0 always. Run as Admin.
# =============================================================================
$ErrorActionPreference = "Continue"
function Log($m) { Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $m" -ForegroundColor Cyan }
function OK($m)  { Write-Host "  [OK] $m" -ForegroundColor Green }

Log "=== dd-lifecycle-enabledisable — Teardown ==="

# Re-enable SSI if it was left disabled
$InstallerPath = "C:\Program Files\Datadog\Datadog Agent\bin\datadog-installer.exe"
if (Test-Path $InstallerPath) {
    & $InstallerPath apm instrument host 2>$null
    OK "SSI re-enabled"
}

$NssmPath = "C:\ProgramData\chocolatey\bin\nssm.exe"
if (Test-Path $NssmPath) {
    & $NssmPath stop   "DDLifecycleTestSvc" 2>$null
    & $NssmPath remove "DDLifecycleTestSvc" confirm 2>$null
} else {
    Stop-Service -Name "DDLifecycleTestSvc" -Force -ErrorAction SilentlyContinue
    sc.exe delete "DDLifecycleTestSvc" 2>$null
}
OK "Service removed"

Remove-Item -Recurse -Force "C:\dd-lifecycle" -ErrorAction SilentlyContinue
netsh advfirewall firewall delete rule name="LifecycleTestSvc" | Out-Null
OK "Teardown complete"
exit 0
