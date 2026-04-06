# =============================================================================
#  dd-java-weblogic — Setup Script
#  Tests SSI injection into wlsvc.exe (Oracle WebLogic Windows service wrapper).
#  The ddinjector java.c detects wlsvc.exe / wlsvcX64.exe as Java injection targets.
#
#  Implementation: Apache Commons Daemon (prunsrv.exe) renamed to wlsvc.exe —
#  accurate simulation of WebLogic's service wrapper since both load the JVM
#  in-process. ddinjector detects by process name and injects the Java tracer.
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
Log "=== dd-java-weblogic — Setup ==="

$ServiceName     = "WlsvcDemoSvc"
$InstallRoot     = "C:\dd-weblogic"
$DaemonDir       = "$InstallRoot\daemon"
$AppDir2         = "$InstallRoot\app"
$LogDir          = "$InstallRoot\logs"
$WlsvcExe        = "$DaemonDir\wlsvc.exe"    # prunsrv.exe renamed to wlsvc.exe
$JarFile         = "$AppDir2\weblogic-demo.jar"
$AppPort         = 8090
$DaemonVersion   = "1.3.4"
$DaemonZipUrl    = "https://downloads.apache.org/commons/daemon/binaries/windows/commons-daemon-${DaemonVersion}-bin-windows.zip"

# -- 1. Install Java 21 -------------------------------------------------------
Log "Step 1: Ensuring Java 21..."
Ensure-Chocolatey
if (-not (Get-Command java -ErrorAction SilentlyContinue)) {
    choco install temurin21 -y --no-progress
    $env:PATH += ";C:\Program Files\Eclipse Adoptium\jdk-21*\bin"
}
$javaVer = (java -version 2>&1 | Select-String "version") -replace '.*version "(.*)".*', '$1'
OK "Java: $javaVer"

# -- 2. Create directories ----------------------------------------------------
New-Item -ItemType Directory -Force -Path $DaemonDir, $AppDir2, $LogDir | Out-Null

# -- 3. Download Apache Commons Daemon — use prunsrv.exe as wlsvc.exe ---------
Log "Step 3: Downloading Apache Commons Daemon (will rename prunsrv.exe -> wlsvc.exe)..."
$zipPath = "$env:TEMP\commons-daemon.zip"
Invoke-WebRequest -Uri $DaemonZipUrl -OutFile $zipPath
Expand-Archive -Path $zipPath -DestinationPath "$env:TEMP\commons-daemon" -Force

$prunsrvSrc = Get-ChildItem "$env:TEMP\commons-daemon" -Recurse -Filter "prunsrv.exe" | Select-Object -First 1
if (-not $prunsrvSrc) { FAIL "prunsrv.exe not found in Commons Daemon zip" }
Copy-Item $prunsrvSrc.FullName $WlsvcExe -Force
OK "wlsvc.exe installed at $WlsvcExe (prunsrv.exe renamed)"

# -- 4. Build app JAR ---------------------------------------------------------
Log "Step 4: Compiling WebLogic demo app..."
$srcDir = Join-Path $AppDir "app\weblogic-demo"
Copy-Item "$srcDir\WebLogicDemoApp.java" $AppDir2 -Force
Push-Location $AppDir2
& javac WebLogicDemoApp.java
& jar cfe weblogic-demo.jar WebLogicDemoApp WebLogicDemoApp.class
Pop-Location
OK "JAR built at $JarFile"

# -- 5. Open firewall ---------------------------------------------------------
Log "Step 5: Opening firewall port $AppPort..."
netsh advfirewall firewall add rule name="WlsvcDemo" dir=in action=allow protocol=TCP localport=$AppPort | Out-Null
OK "Firewall port $AppPort open"

# -- 6. Register service using wlsvc.exe (prunsrv renamed) --------------------
Log "Step 6: Registering Windows service via wlsvc.exe (WebLogic wrapper simulation)..."
& $WlsvcExe //DS//$ServiceName 2>$null
Start-Sleep -Seconds 1

$javaHome = (Get-Command java).Source | Split-Path | Split-Path

& $WlsvcExe //IS//$ServiceName `
    --DisplayName="Datadog WebLogic SSI Demo (wlsvc.exe)" `
    --Description="Tests SSI injection into wlsvc.exe via java.c process detection" `
    --Startup=auto `
    --StartMode=Java `
    --JavaHome="$javaHome" `
    --StartClass=WebLogicDemoApp `
    --Classpath="$JarFile" `
    --LogPath="$LogDir" `
    --LogPrefix=weblogic-demo `
    --StdOutput="$LogDir\stdout.log" `
    --StdError="$LogDir\stderr.log"

if ($LASTEXITCODE -ne 0) {
    # Fallback: jvm mode
    & $WlsvcExe //IS//$ServiceName `
        --DisplayName="Datadog WebLogic SSI Demo (wlsvc.exe)" `
        --Startup=auto `
        --StartMode=Jvm `
        --Classpath="$JarFile" `
        --StartClass=WebLogicDemoApp `
        --LogPath="$LogDir"
}

# Set DD environment variables on the service
$regSvcPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
if (Test-Path $regSvcPath) {
    New-ItemProperty -Path $regSvcPath -Name "Environment" -PropertyType MultiString -Force -Value @(
        "DD_SERVICE=java-weblogic-app",
        "DD_ENV=demo",
        "DD_VERSION=1.0"
    ) | Out-Null
}
OK "Service $ServiceName registered (wlsvc.exe process)"

# -- 7. Install Datadog Agent + SSI -------------------------------------------
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
}

# -- 8. Start service ---------------------------------------------------------
Log "Step 8: Starting service $ServiceName..."
Start-Service -Name $ServiceName -ErrorAction SilentlyContinue
Start-Sleep -Seconds 8

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq "Running") {
    OK "Service running — SSI injection triggered into wlsvc.exe"
} else {
    FAIL "Service failed to start. Check logs in $LogDir"
}

if ($Verify) {
    & "$ScriptDir\verify.ps1" -TargetHost "localhost" -DDApiKey $DDApiKey -DDSite $DDSite
}

Log "=== Setup complete ==="
