# =============================================================================
#  dd-java-double-inject-prevention — Teardown Script. Exit 0 always. Run as Admin.
# =============================================================================
$ErrorActionPreference = "Continue"
function Log($m) { Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $m" -ForegroundColor Cyan }
function OK($m)  { Write-Host "  [OK] $m" -ForegroundColor Green }

Log "=== dd-java-double-inject-prevention — Teardown ==="

$NssmPath = "C:\ProgramData\chocolatey\bin\nssm.exe"
if (Test-Path $NssmPath) {
    & $NssmPath stop   "DDDoubleInjectTestSvc" 2>$null
    & $NssmPath remove "DDDoubleInjectTestSvc" confirm 2>$null
} else {
    Stop-Service -Name "DDDoubleInjectTestSvc" -Force -ErrorAction SilentlyContinue
    sc.exe delete "DDDoubleInjectTestSvc" 2>$null
}
OK "Service removed"

Remove-Item -Recurse -Force "C:\dd-double-inject" -ErrorAction SilentlyContinue
netsh advfirewall firewall delete rule name="DoubleInjectTest" | Out-Null
OK "Teardown complete"
exit 0
