$ErrorActionPreference = "Continue"
function Log($m) { Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $m" -ForegroundColor Cyan }
function OK($m)  { Write-Host "  [OK] $m" -ForegroundColor Green }

Log "=== dd-dotnet-x86 — Teardown ==="

Stop-Service -Name "DDX86Svc" -Force -ErrorAction SilentlyContinue
sc.exe delete "DDX86Svc" 2>$null
OK "Service removed"

Remove-Item -Recurse -Force "C:\dd-x86" -ErrorAction SilentlyContinue
netsh advfirewall firewall delete rule name="DotnetX86App" | Out-Null
OK "Teardown complete"
exit 0
