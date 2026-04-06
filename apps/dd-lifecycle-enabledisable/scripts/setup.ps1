# =============================================================================
#  dd-lifecycle-enabledisable — Setup Script
#  Tests the SSI enable/disable lifecycle using the datadog-installer.exe
#  "apm instrument host" / "apm uninstrument host" commands.
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
Log "=== dd-lifecycle-enabledisable — Setup ==="

$ServiceName     = "DDLifecycleTestSvc"
$InstallPath     = "C:\dd-lifecycle"
$NssmPath        = "C:\ProgramData\chocolatey\bin\nssm.exe"
$InstallerPath   = "C:\Program Files\Datadog\Datadog Agent\bin\datadog-installer.exe"
$AppPort         = 8088

# ── 1. Install .NET SDK + NSSM ────────────────────────────────────────────────
Log "Step 1: Ensuring .NET SDK and NSSM..."
Ensure-Chocolatey
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    choco install dotnet-sdk -y --no-progress
}
if (-not (Test-Path $NssmPath)) {
    choco install nssm -y --no-progress
}
OK ".NET SDK and NSSM available"

# ── 2. Create a simple HTTP service app inline ────────────────────────────────
Log "Step 2: Creating lifecycle test HTTP service..."
New-Item -ItemType Directory -Force -Path $InstallPath | Out-Null
New-Item -ItemType Directory -Force -Path "$InstallPath\src" | Out-Null

@'
<Project Sdk="Microsoft.NET.Sdk.Web">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net8.0</TargetFramework>
    <AssemblyName>LifecycleTestSvc</AssemblyName>
  </PropertyGroup>
</Project>
'@ | Out-File -FilePath "$InstallPath\src\LifecycleTestSvc.csproj" -Encoding utf8 -Force

@'
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Hosting;

var builder = WebApplication.CreateBuilder(args);
builder.WebHost.UseUrls("http://0.0.0.0:8088");
var app = builder.Build();

app.MapGet("/health", () => Results.Json(new {
    status = "ok",
    service = "lifecycle-test-svc",
    version = "1.0"
}));

app.Run();
'@ | Out-File -FilePath "$InstallPath\src\Program.cs" -Encoding utf8 -Force

Push-Location "$InstallPath\src"
dotnet publish LifecycleTestSvc.csproj --configuration Release --output "$InstallPath\bin"
Pop-Location
OK "Lifecycle test service built"

# ── 3. Open firewall ───────────────────────────────────────────────────────────
netsh advfirewall firewall add rule name="LifecycleTestSvc" dir=in action=allow protocol=TCP localport=$AppPort | Out-Null

# ── 4. Register Windows Service via NSSM ──────────────────────────────────────
Log "Step 4: Registering service..."
& $NssmPath stop   $ServiceName 2>$null
& $NssmPath remove $ServiceName confirm 2>$null
Start-Sleep -Seconds 2

& $NssmPath install $ServiceName "$InstallPath\bin\LifecycleTestSvc.exe"
& $NssmPath set     $ServiceName AppDirectory "$InstallPath\bin"
& $NssmPath set     $ServiceName DisplayName  "Datadog SSI Lifecycle Test Service"
& $NssmPath set     $ServiceName Start        SERVICE_AUTO_START
& $NssmPath set     $ServiceName AppEnvironmentExtra "DD_SERVICE=lifecycle-test-svc" "DD_ENV=demo" "DD_VERSION=1.0"
OK "Service registered"

# ── 5. Install Datadog Agent + SSI ────────────────────────────────────────────
if ($InstallAgent) {
    if (-not $DDApiKey) { FAIL "-InstallAgent requires -DDApiKey or DD_API_KEY env var" }

    Log "Installing Datadog Agent (with SSI)..."
    $msiArgs = "/qn /i `"https://windows-agent.datadoghq.com/datadog-agent-7-latest.amd64.msi`"" +
               " /log C:\Windows\SystemTemp\install-datadog.log" +
               " APIKEY=`"$DDApiKey`" SITE=`"$DDSite`"" +
               " DD_APM_INSTRUMENTATION_ENABLED=`"host`"" +
               " DD_APM_INSTRUMENTATION_LIBRARIES=`"dotnet:3`""
    $p = Start-Process -Wait -PassThru msiexec -ArgumentList $msiArgs
    if ($p.ExitCode -ne 0) { FAIL "msiexec failed ($($p.ExitCode)) — check C:\Windows\SystemTemp\install-datadog.log" }
    OK "Datadog Agent installed with SSI"
}

# ── 6. Ensure SSI is enabled then start service ────────────────────────────────
Log "Step 6: Enabling SSI via apm instrument host..."
if (Test-Path $InstallerPath) {
    & $InstallerPath apm instrument host
    OK "SSI enabled via datadog-installer.exe apm instrument host"
} else {
    Log "datadog-installer.exe not found — SSI may already be enabled via agent installation"
}

Start-Service -Name $ServiceName
Start-Sleep -Seconds 5
OK "Service started — Phase 1 (ENABLED) ready for verify.ps1"

if ($Verify) {
    & "$ScriptDir\verify.ps1" -TargetHost "localhost" -DDApiKey $DDApiKey -DDSite $DDSite
}

Log "=== Setup complete ==="
