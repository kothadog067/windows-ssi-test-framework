# =============================================================================
#  dd-skiplist-negative — Teardown Script. Exit 0 always. Run as Admin.
# =============================================================================
$ErrorActionPreference = "Continue"
function Log($m) { Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $m" -ForegroundColor Cyan }
function OK($m)  { Write-Host "  [OK] $m" -ForegroundColor Green }

Log "=== dd-skiplist-negative — Teardown ==="

# Stop notepad canary process
Stop-Process -Name "notepad" -Force -ErrorAction SilentlyContinue
OK "Canary processes stopped"

OK "Teardown complete"
exit 0
