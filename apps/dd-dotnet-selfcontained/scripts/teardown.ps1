# =============================================================================
#  dd-dotnet-selfcontained — Teardown Script. Exit 0 always. Run as Admin.
# =============================================================================
$ErrorActionPreference = "Continue"
function Log($m) { Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $m" -ForegroundColor Cyan }
function OK($m)  { Write-Host "  [OK] $m" -ForegroundColor Green }

Log "=== dd-dotnet-selfcontained — Teardown ==="

Stop-Service -Name "DDSelfContainedSvc" -Force -ErrorAction SilentlyContinue
sc.exe delete "DDSelfContainedSvc" 2>$null
OK "Service removed"

Remove-Item -Recurse -Force "C:\dd-selfcontained" -ErrorAction SilentlyContinue
OK "App directory removed"

netsh advfirewall firewall delete rule name="DotnetSelfContained" | Out-Null
OK "Firewall rule removed"

OK "Teardown complete"
exit 0
