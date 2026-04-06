# =============================================================================
#  dd-dotnet-framework — Setup Script
#  Tests SSI injection into a .NET Framework 4.8 application.
#  The ddinjector dotnet.c detects Framework apps via PE COM descriptor
#  (IMAGE_DIRECTORY_ENTRY_COM_DESCRIPTOR present only in managed assemblies).
#  Process name: DotnetFramework.exe, Port: 8087
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
Log "=== dd-dotnet-framework — Setup ==="

$ServiceName = "DDFrameworkSvc"
$InstallPath = "C:\dd-framework"
$ExePath     = "$InstallPath\DotnetFramework.exe"
$SourceDir   = Join-Path $AppDir "app\framework-app"
$AppPort     = 8087
$NssmPath    = "C:\ProgramData\chocolatey\bin\nssm.exe"

# ── 1. Install .NET Framework 4.8 Dev Pack (if needed) ────────────────────────
Log "Step 1: Ensuring .NET Framework 4.8 build tools..."
Ensure-Chocolatey
# .NET Framework 4.8 is included in Windows Server 2019/2022/2025
# We need the SDK to build. Use dotnet SDK targeting net48.
$dotnetVer = dotnet --version 2>&1
if ($LASTEXITCODE -ne 0) {
    choco install dotnet-sdk -y --no-progress
}
OK ".NET SDK available: $dotnetVer"

# ── 2. Build the .NET Framework 4.8 app ───────────────────────────────────────
Log "Step 2: Building .NET Framework 4.8 app..."
New-Item -ItemType Directory -Force -Path $InstallPath | Out-Null

Push-Location $SourceDir
dotnet publish DotnetFramework.csproj `
    --configuration Release `
    --output $InstallPath
Pop-Location

if (-not (Test-Path $ExePath)) {
    FAIL "Build failed: $ExePath not found after publish"
}
OK "Built and published to $ExePath"

# ── 3. Install NSSM (service wrapper for .exe with no ServiceBase) ─────────────
Log "Step 3: Installing NSSM..."
if (-not (Test-Path $NssmPath)) {
    choco install nssm -y --no-progress
}
OK "NSSM available"

# ── 4. Open firewall ───────────────────────────────────────────────────────────
Log "Step 4: Opening firewall port $AppPort..."
netsh advfirewall firewall add rule name="DotnetFramework" dir=in action=allow protocol=TCP localport=$AppPort | Out-Null

# HttpListener needs URL ACL
netsh http add urlacl url="http://+:$AppPort/" user="NT AUTHORITY\NetworkService" 2>$null
OK "Firewall and URL ACL configured"

# ── 5. Register service via NSSM ──────────────────────────────────────────────
Log "Step 5: Registering Windows service $ServiceName..."
& $NssmPath stop   $ServiceName 2>$null
& $NssmPath remove $ServiceName confirm 2>$null
Start-Sleep -Seconds 2

& $NssmPath install $ServiceName $ExePath
& $NssmPath set     $ServiceName AppDirectory  $InstallPath
& $NssmPath set     $ServiceName DisplayName   "Datadog .NET Framework 4.8 SSI Demo"
& $NssmPath set     $ServiceName Description   "Tests SSI injection into .NET Framework 4.8 via PE COM descriptor detection"
& $NssmPath set     $ServiceName Start         SERVICE_AUTO_START

# Set Datadog env vars on the NSSM service
& $NssmPath set $ServiceName AppEnvironmentExtra `
    "DD_SERVICE=dotnet-framework-app" `
    "DD_ENV=demo" `
    "DD_VERSION=1.0"

OK "Service $ServiceName registered via NSSM"

# ── 6. Install Datadog Agent + SSI ────────────────────────────────────────────
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

# ── 7. Start service ───────────────────────────────────────────────────────────
Log "Step 7: Starting service $ServiceName..."
Start-Service -Name $ServiceName
Start-Sleep -Seconds 5

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq "Running") {
    OK "Service running — SSI injection triggered into DotnetFramework.exe (PE COM descriptor path)"
} else {
    FAIL "Service failed to start"
}

if ($Verify) {
    & "$ScriptDir\verify.ps1" -TargetHost "localhost" -DDApiKey $DDApiKey -DDSite $DDSite
}

Log "=== Setup complete ==="
