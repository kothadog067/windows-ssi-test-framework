$ErrorActionPreference = "Continue"
function Log($m) { Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $m" -ForegroundColor Cyan }
function OK($m)  { Write-Host "  [OK] $m" -ForegroundColor Green }

Log "=== dd-java-weblogic — Teardown ==="

$WlsvcExe = "C:\dd-weblogic\daemon\wlsvc.exe"
if (Test-Path $WlsvcExe) {
    & $WlsvcExe //DS//WlsvcDemoSvc 2>$null
} else {
    Stop-Service -Name "WlsvcDemoSvc" -Force -ErrorAction SilentlyContinue
    sc.exe delete "WlsvcDemoSvc" 2>$null
}
OK "Service removed"

Remove-Item -Recurse -Force "C:\dd-weblogic" -ErrorAction SilentlyContinue
netsh advfirewall firewall delete rule name="WlsvcDemo" | Out-Null
OK "Teardown complete"
exit 0
