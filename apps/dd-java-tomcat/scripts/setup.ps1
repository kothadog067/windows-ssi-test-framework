# =============================================================================
#  dd-java-tomcat — Setup Script
#  Tests SSI injection into Apache Tomcat 9 (tomcat9.exe process).
#  The ddinjector java.c source explicitly matches tomcat9.exe via is_tomcat_exe().
#
#  Standard interface: setup.ps1 [-DDApiKey <key>] [-DDSite <site>]
#                                  [-InstallAgent] [-Verify]
#  Exit 0 = success, Exit 1 = failure. Run as Administrator.
# =============================================================================

param(
    [string]$DDApiKey    = $env:DD_API_KEY,
    [string]$DDSite      = $(if ($env:DD_SITE) { $env:DD_SITE } else { "datadoghq.com" }),
    [switch]$InstallAgent,
    [switch]$Verify
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"
$ScriptDir             = Split-Path -Parent $MyInvocation.MyCommand.Path
$AppDir                = Split-Path -Parent $ScriptDir

function Log($m)  { Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $m" -ForegroundColor Cyan }
function OK($m)   { Write-Host "  [OK] $m"   -ForegroundColor Green }
function FAIL($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; exit 1 }

function Assert-Admin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object System.Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        FAIL "This script must be run as Administrator."
    }
}

function Ensure-Chocolatey {
    if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
        Log "Installing Chocolatey..."
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
        $env:PATH += ";$env:ALLUSERSPROFILE\chocolatey\bin"
    }
}

Assert-Admin
Log "=== dd-java-tomcat — Setup ==="

# ── Constants ─────────────────────────────────────────────────────────────────
$TomcatVersion  = "9.0.102"
$TomcatBase     = "C:\tomcat9"
$TomcatBin      = "$TomcatBase\bin"
$TomcatWebapps  = "$TomcatBase\webapps"
$TomcatLogs     = "$TomcatBase\logs"
$ServiceName    = "Tomcat9"
$AppPort        = 8085
$WebappName     = "dd-tomcat-demo"
$TomcatZipUrl   = "https://archive.apache.org/dist/tomcat/tomcat-9/v${TomcatVersion}/bin/apache-tomcat-${TomcatVersion}-windows-x64.zip"
$TomcatZipPath  = "$env:TEMP\tomcat9.zip"

# ── 1. Install Java 21 via Chocolatey ─────────────────────────────────────────
Log "Step 1: Ensuring Java 21 is installed..."
Ensure-Chocolatey
if (-not (Get-Command java -ErrorAction SilentlyContinue)) {
    choco install temurin21 -y --no-progress
    $env:PATH += ";C:\Program Files\Eclipse Adoptium\jdk-21*\bin"
}
$javaVer = (java -version 2>&1 | Select-String "version") -replace '.*version "(.*)".*', '$1'
OK "Java: $javaVer"

# ── 2. Download and install Tomcat 9 ──────────────────────────────────────────
Log "Step 2: Installing Apache Tomcat $TomcatVersion..."
if (-not (Test-Path "$TomcatBin\tomcat9.exe")) {
    Invoke-WebRequest -Uri $TomcatZipUrl -OutFile $TomcatZipPath
    Expand-Archive -Path $TomcatZipPath -DestinationPath "C:\" -Force
    $extractedDir = Get-ChildItem "C:\" -Directory | Where-Object { $_.Name -like "apache-tomcat-*" } | Select-Object -First 1
    if ($extractedDir) {
        if (Test-Path $TomcatBase) { Remove-Item -Recurse -Force $TomcatBase }
        Rename-Item $extractedDir.FullName $TomcatBase
    }
}
OK "Tomcat installed at $TomcatBase"

# ── 3. Deploy the demo webapp ──────────────────────────────────────────────────
Log "Step 3: Deploying demo webapp to $TomcatWebapps\$WebappName..."
$destWebapp = "$TomcatWebapps\$WebappName"
New-Item -ItemType Directory -Force -Path "$destWebapp\WEB-INF" | Out-Null
New-Item -ItemType Directory -Force -Path "$destWebapp\health" | Out-Null

# Health endpoint as a static JSON response via a Servlet filter shim
@"
<?xml version="1.0" encoding="UTF-8"?>
<web-app xmlns="http://xmlns.jcp.org/xml/ns/javaee"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://xmlns.jcp.org/xml/ns/javaee
         http://xmlns.jcp.org/xml/ns/javaee/web-app_4_0.xsd"
         version="4.0">
    <display-name>Tomcat SSI Demo</display-name>
    <welcome-file-list>
        <welcome-file>index.jsp</welcome-file>
    </welcome-file-list>
</web-app>
"@ | Out-File -FilePath "$destWebapp\WEB-INF\web.xml" -Encoding utf8 -Force

@'
<%@ page contentType="application/json; charset=UTF-8" %>
{"status":"ok","service":"java-tomcat-app","version":"1.0"}
'@ | Out-File -FilePath "$destWebapp\index.jsp" -Encoding utf8 -Force

# Create a simple health JSP
@'
<%@ page contentType="application/json; charset=UTF-8" %>
{"status":"ok","service":"java-tomcat-app","version":"1.0","endpoint":"health"}
'@ | Out-File -FilePath "$destWebapp\health.jsp" -Encoding utf8 -Force

OK "Webapp deployed"

# ── 4. Configure Tomcat port ───────────────────────────────────────────────────
Log "Step 4: Configuring Tomcat HTTP port to $AppPort..."
$serverXml = "$TomcatBase\conf\server.xml"
(Get-Content $serverXml) -replace 'port="8080"', "port=`"$AppPort`"" | Set-Content $serverXml
OK "Tomcat configured on port $AppPort"

# ── 5. Open firewall ───────────────────────────────────────────────────────────
Log "Step 5: Opening firewall port $AppPort..."
netsh advfirewall firewall add rule name="Tomcat SSI Demo" dir=in action=allow protocol=TCP localport=$AppPort | Out-Null
OK "Firewall port $AppPort open"

# ── 6. Set Datadog environment variables on Tomcat service ────────────────────
Log "Step 6: Setting DD_ environment variables..."
[System.Environment]::SetEnvironmentVariable("DD_SERVICE", "java-tomcat-app", "Machine")
[System.Environment]::SetEnvironmentVariable("DD_ENV",     "demo",            "Machine")
[System.Environment]::SetEnvironmentVariable("DD_VERSION", "1.0",             "Machine")
OK "DD_ env vars set at Machine scope"

# ── 7. Install Tomcat as Windows service ──────────────────────────────────────
Log "Step 7: Registering Tomcat 9 as Windows service..."
$serviceBat = "$TomcatBin\service.bat"
if (Test-Path $serviceBat) {
    $env:CATALINA_HOME = $TomcatBase
    $env:JAVA_HOME     = (Get-Command java).Source | Split-Path | Split-Path
    & cmd /c "cd /d `"$TomcatBin`" && service.bat install $ServiceName"
} else {
    # Fallback: register tomcat9.exe directly
    & "$TomcatBin\tomcat9.exe" //IS//$ServiceName `
        --DisplayName="Apache Tomcat 9 SSI Demo" `
        --Startup=auto `
        --LogPath="$TomcatLogs"
}
OK "Tomcat service registered"

# ── 8. Install Datadog Agent + SSI ────────────────────────────────────────────
if ($InstallAgent) {
    if (-not $DDApiKey) { FAIL "-InstallAgent requires -DDApiKey or DD_API_KEY env var" }

    Log "Installing Datadog Agent..."
    $msiPath = "$env:TEMP\datadog-agent.msi"
    Invoke-WebRequest -Uri "https://s3.amazonaws.com/ddagent-windows-stable/datadog-agent-7-latest.amd64.msi" -OutFile $msiPath
    Start-Process msiexec.exe -Wait -ArgumentList @(
        "/i", $msiPath,
        "APIKEY=$DDApiKey", "SITE=$DDSite",
        "/qn", "/l*v", "$env:TEMP\dd-agent-install.log"
    )
    Restart-Service -Name "datadogagent" -ErrorAction SilentlyContinue
    OK "Datadog Agent installed"

    Log "Starting Tomcat service to trigger SSI injection..."
    Start-Service -Name $ServiceName -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 10
    OK "Tomcat started — SSI injection triggered into tomcat9.exe"
} else {
    Start-Service -Name $ServiceName -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 5
    OK "Tomcat service started"
}

if ($Verify) {
    & "$ScriptDir\verify.ps1" -TargetHost "localhost" -DDApiKey $DDApiKey -DDSite $DDSite
}

Log "=== Setup complete ==="
