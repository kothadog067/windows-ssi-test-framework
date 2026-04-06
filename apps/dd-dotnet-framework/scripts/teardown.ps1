# =============================================================================
#  dd-dotnet-framework — Teardown Script. Exit 0 always. Run as Admin.
# =============================================================================
$ErrorActionPreference = "Continue"
function Log($m) { Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $m" -ForegroundColor Cyan }
function OK($m)  { Write-Host "  [OK] $m" -ForegroundColor Green }

Log "=== dd-dotnet-framework — Teardown ==="

$NssmPath = "C:\ProgramData\chocolatey\bin\nssm.exe"
if (Test-Path $NssmPath) {
    & $NssmPath stop   "DDFrameworkSvc" 2>$null
    & $NssmPath remove "DDFrameworkSvc" confirm 2>$null
} else {
    Stop-Service -Name "DDFrameworkSvc" -Force -ErrorAction SilentlyContinue
    sc.exe delete "DDFrameworkSvc" 2>$null
}
OK "Service removed"

Remove-Item -Recurse -Force "C:\dd-framework" -ErrorAction SilentlyContinue
OK "App directory removed"

netsh advfirewall firewall delete rule name="DotnetFramework" | Out-Null
netsh http delete urlacl url="http://+:8087/" 2>$null | Out-Null
OK "Firewall rules removed"

OK "Teardown complete"
exit 0
