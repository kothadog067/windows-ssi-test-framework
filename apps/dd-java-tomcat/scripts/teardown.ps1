# =============================================================================
#  dd-java-tomcat — Teardown Script
#  Stops and removes the Tomcat 9 service, cleans up files.
#  Exit 0 always. Run as Administrator.
# =============================================================================

$ErrorActionPreference = "Continue"

function Log($m) { Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $m" -ForegroundColor Cyan }
function OK($m)  { Write-Host "  [OK] $m" -ForegroundColor Green }

Log "=== dd-java-tomcat — Teardown ==="

# Stop and remove Tomcat service
Stop-Service -Name "Tomcat9" -Force -ErrorAction SilentlyContinue
$tomcatBin = "C:\tomcat9\bin"
if (Test-Path "$tomcatBin\tomcat9.exe") {
    & "$tomcatBin\tomcat9.exe" //DS//Tomcat9 2>$null
}
& sc.exe delete "Tomcat9" 2>$null
OK "Tomcat9 service removed"

# Remove Tomcat installation
Remove-Item -Recurse -Force "C:\tomcat9" -ErrorAction SilentlyContinue
OK "Tomcat installation removed"

# Remove firewall rule
netsh advfirewall firewall delete rule name="Tomcat SSI Demo" | Out-Null
OK "Firewall rule removed"

# Remove DD_ machine env vars
foreach ($v in @("DD_SERVICE","DD_ENV","DD_VERSION")) {
    [System.Environment]::SetEnvironmentVariable($v, $null, "Machine")
}
OK "DD_ env vars removed"

OK "Teardown complete"
exit 0
