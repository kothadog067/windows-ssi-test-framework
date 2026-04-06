<#
.SYNOPSIS
    Installs and configures the dd-java-procrun application as a Windows Service
    managed by Apache Commons Daemon (Procrun).

.DESCRIPTION
    - Verifies Java is present (or installs via Chocolatey)
    - Downloads Apache Commons Daemon 1.3.x (zip), extracts prunsrv.exe
    - Compiles ProcrunApp.java
    - Registers a Windows Service (JavaProcrunSvc) using prunsrv.exe
    - Sets DD_SERVICE / DD_ENV / DD_VERSION / DD_API_KEY as service environment vars
    - Starts the service
    - Optionally installs the Datadog Agent

.PARAMETER DDApiKey
    Datadog API key. Required when -InstallAgent is specified.

.PARAMETER DDSite
    Datadog intake site. Defaults to datadoghq.com.

.PARAMETER InstallAgent
    When present, downloads and installs the Datadog Windows Agent MSI.

.PARAMETER Verify
    When present, runs verify.ps1 after setup.

.EXAMPLE
    .\setup.ps1 -DDApiKey "abc123" -DDSite "datadoghq.com" -InstallAgent -Verify
#>
[CmdletBinding()]
param(
    [string]$DDApiKey   = "",
    [string]$DDSite     = "datadoghq.com",
    [switch]$InstallAgent,
    [switch]$Verify
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step { param([string]$Msg) Write-Host "`n==> $Msg" -ForegroundColor Cyan }
function Write-OK   { param([string]$Msg) Write-Host "    [OK] $Msg" -ForegroundColor Green }

function Assert-Admin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object System.Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "This script must be run as Administrator."
    }
}

function Ensure-Chocolatey {
    if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
        Write-Step "Installing Chocolatey"
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
        $env:PATH += ";$env:ALLUSERSPROFILE\chocolatey\bin"
    }
}

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
$ServiceName     = "JavaProcrunSvc"
$DisplayName     = "Datadog Java Procrun Demo"
$InstallRoot     = "C:\dd-java-procrun"
$AppDir          = Join-Path $InstallRoot "app"
$DaemonDir       = Join-Path $InstallRoot "daemon"
$LogDir          = Join-Path $InstallRoot "logs"
$PrunsrvExe      = Join-Path $DaemonDir "prunsrv.exe"
$JarFile         = Join-Path $AppDir "procrun-app.jar"
$ScriptDir       = $PSScriptRoot
$SourceDir       = Join-Path $ScriptDir "..\app\java-procrun-app"

# Apache Commons Daemon 1.3.4
$DaemonVersion   = "1.3.4"
$DaemonZipUrl    = "https://downloads.apache.org/commons/daemon/binaries/windows/commons-daemon-${DaemonVersion}-bin-windows.zip"
$DaemonZipPath   = "$env:TEMP\commons-daemon.zip"

Assert-Admin
Write-Step "Starting dd-java-procrun setup"

# ---------------------------------------------------------------------------
# 1. Chocolatey + Java
# ---------------------------------------------------------------------------
Ensure-Chocolatey

if (-not (Get-Command java -ErrorAction SilentlyContinue)) {
    Write-Step "Installing Java 17 (Microsoft OpenJDK) via Chocolatey"
    choco install microsoft-openjdk17 -y --no-progress 2>&1 | Out-Null
    $env:PATH += ";$env:ProgramFiles\Microsoft\jdk-17.0*\bin"
}
$javaVersion = java -version 2>&1 | Select-Object -First 1
Write-OK "Java: $javaVersion"

# ---------------------------------------------------------------------------
# 2. Create directories
# ---------------------------------------------------------------------------
Write-Step "Creating installation directories"
foreach ($d in @($InstallRoot, $AppDir, $DaemonDir, $LogDir)) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}
Write-OK "Directories ready"

# ---------------------------------------------------------------------------
# 3. Download and extract Apache Commons Daemon (prunsrv.exe)
# ---------------------------------------------------------------------------
Write-Step "Downloading Apache Commons Daemon $DaemonVersion"
$wc = New-Object System.Net.WebClient
$wc.DownloadFile($DaemonZipUrl, $DaemonZipPath)
Write-OK "Downloaded to $DaemonZipPath"

Write-Step "Extracting prunsrv.exe"
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead($DaemonZipPath)
try {
    foreach ($entry in $zip.Entries) {
        # We want the 64-bit prunsrv.exe (located at amd64/prunsrv.exe in the zip)
        if ($entry.FullName -match "amd64[/\\]prunsrv\.exe$") {
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $PrunsrvExe, $true)
            Write-OK "Extracted: $PrunsrvExe"
            break
        }
    }
} finally {
    $zip.Dispose()
}
Remove-Item $DaemonZipPath -Force -ErrorAction SilentlyContinue

if (-not (Test-Path $PrunsrvExe)) {
    throw "prunsrv.exe was not found in the zip. Check the archive layout."
}

# ---------------------------------------------------------------------------
# 4. Compile ProcrunApp.java → JAR
# ---------------------------------------------------------------------------
Write-Step "Compiling ProcrunApp.java"
$classDir = Join-Path $env:TEMP "procrun-classes"
New-Item -ItemType Directory -Force -Path $classDir | Out-Null

javac -d $classDir (Join-Path $SourceDir "ProcrunApp.java")
if ($LASTEXITCODE -ne 0) { throw "javac failed" }

# Build the JAR with the manifest
$manifestSrc = Join-Path $SourceDir "Manifest.txt"
jar cfm $JarFile $manifestSrc -C $classDir .
if ($LASTEXITCODE -ne 0) { throw "jar creation failed" }

Remove-Item $classDir -Recurse -Force -ErrorAction SilentlyContinue
Write-OK "Compiled to $JarFile"

# ---------------------------------------------------------------------------
# 5. Remove existing service if present
# ---------------------------------------------------------------------------
$existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Step "Removing existing service: $ServiceName"
    if ($existing.Status -ne "Stopped") {
        & $PrunsrvExe //SS//$ServiceName 2>&1 | Out-Null
        Start-Sleep -Seconds 3
    }
    & $PrunsrvExe //DS//$ServiceName 2>&1 | Out-Null
    Write-OK "Existing service removed"
}

# ---------------------------------------------------------------------------
# 6. Register Windows Service via prunsrv.exe
# ---------------------------------------------------------------------------
Write-Step "Registering Windows Service: $ServiceName"

# Locate javaw.exe for the JVM path
$javaHome = (Get-Command java).Source | Split-Path | Split-Path
$jvmDll   = Join-Path $javaHome "bin\server\jvm.dll"
if (-not (Test-Path $jvmDll)) {
    # Fallback path used by some JDKs
    $jvmDll = Join-Path $javaHome "jre\bin\server\jvm.dll"
}

# Build environment string: key=value pairs separated by #
$envVars = "DD_SERVICE=java-procrun-app#DD_ENV=demo#DD_VERSION=1.0.0"
if ($DDApiKey) { $envVars += "#DD_API_KEY=$DDApiKey" }
if ($DDSite)   { $envVars += "#DD_SITE=$DDSite"      }

& $PrunsrvExe //IS//$ServiceName `
    "--DisplayName=$DisplayName" `
    "--Description=Datadog Java Procrun SSI test app" `
    "--Install=$PrunsrvExe" `
    "--LogPath=$LogDir" `
    "--LogLevel=Info" `
    "--StdOutput=$LogDir\stdout.log" `
    "--StdError=$LogDir\stderr.log" `
    "--Startup=auto" `
    "--StartMode=Java" `
    "--StartClass=ProcrunApp" `
    "--StartMethod=start" `
    "--StopMode=Java" `
    "--StopClass=ProcrunApp" `
    "--StopMethod=stop" `
    "--Classpath=$JarFile" `
    "--Jvm=$jvmDll" `
    "--JvmMs=64" `
    "--JvmMx=256" `
    "--Environment=$envVars"

if ($LASTEXITCODE -ne 0) { throw "prunsrv //IS// failed with exit code $LASTEXITCODE" }
Write-OK "Service registered"

# ---------------------------------------------------------------------------
# 7. Start the service
# ---------------------------------------------------------------------------
Write-Step "Starting service: $ServiceName"
Start-Service -Name $ServiceName
Start-Sleep -Seconds 5
$svc = Get-Service -Name $ServiceName
Write-OK "Service state: $($svc.Status)"

# ---------------------------------------------------------------------------
# 8. Optional: Datadog Agent
# ---------------------------------------------------------------------------
if ($InstallAgent) {
    if (-not $DDApiKey) { throw "-DDApiKey is required when -InstallAgent is specified." }
    Write-Step "Installing Datadog Agent"
    $msiUrl  = "https://s3.amazonaws.com/ddagent-windows-stable/datadog-agent-7-latest.amd64.msi"
    $msiPath = "$env:TEMP\datadog-agent.msi"
    (New-Object System.Net.WebClient).DownloadFile($msiUrl, $msiPath)
    $msiArgs = "/qn /i `"$msiPath`" APIKEY=`"$DDApiKey`" SITE=`"$DDSite`" TAGS=`"env:demo`""
    Start-Process msiexec.exe -ArgumentList $msiArgs -Wait -NoNewWindow
    Remove-Item $msiPath -Force -ErrorAction SilentlyContinue
    Write-OK "Datadog Agent installed"
}

# ---------------------------------------------------------------------------
# 9. Optional verify
# ---------------------------------------------------------------------------
if ($Verify) {
    Write-Step "Running verify.ps1"
    & (Join-Path $ScriptDir "verify.ps1") -TargetHost "localhost" -DDApiKey $DDApiKey -DDSite $DDSite
}

Write-Host "`n[DONE] dd-java-procrun setup complete." -ForegroundColor Green
