# =============================================================================
#  dd-dotnet-x86 — Setup Script
#  Tests SSI injection into a 32-bit (x86) .NET 8 self-contained process.
#  The ddinjector ships ddinjector_x86.dll for 32-bit processes, separate from
#  ddinjector_x64.dll used for 64-bit processes. This tests the x86 injection path.
#
#  Process name: DotnetX86App.exe (32-bit), Port: 8091
#  DLL to check: ddinjector_x86.dll (NOT ddinjector_x64.dll)
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

Assert-Admin
Log "=== dd-dotnet-x86 — Setup ==="

$ServiceName = "DDX86Svc"
$InstallPath = "C:\dd-x86"
$ExePath     = "$InstallPath\DotnetX86App.exe"
$SourceDir   = Join-Path $AppDir "app\x86-app"
$AppPort     = 8091

# -- 1. Publish as 32-bit self-contained win-x86 ------------------------------
Log "Step 1: Publishing .NET 8 as 32-bit self-contained (win-x86)..."
New-Item -ItemType Directory -Force -Path $InstallPath | Out-Null

Push-Location $SourceDir
dotnet publish DotnetX86App.csproj `
    --configuration Release `
    --runtime win-x86 `
    --self-contained true `
    -p:PublishSingleFile=true `
    -p:IncludeNativeLibrariesForSelfExtract=true `
    --output $InstallPath
Pop-Location

if (-not (Test-Path $ExePath)) {
    FAIL "Build failed: $ExePath not found after publish"
}

# Verify it's actually 32-bit
$peHeader = [System.IO.File]::ReadAllBytes($ExePath)
# PE signature at offset 0x3c, machine type at PE+4
$peOffset = [System.BitConverter]::ToUInt32($peHeader, 0x3c)
$machineType = [System.BitConverter]::ToUInt16($peHeader, $peOffset + 4)
# 0x14c = x86 (IMAGE_FILE_MACHINE_I386), 0x8664 = x64
if ($machineType -eq 0x14c) {
    OK "Confirmed 32-bit (x86) executable (machine type 0x14c = IMAGE_FILE_MACHINE_I386)"
} else {
    Log "WARNING: Machine type 0x$($machineType.ToString('x4')) — may not be x86. Proceeding anyway."
}

# -- 2. Open firewall ---------------------------------------------------------
Log "Step 2: Opening firewall port $AppPort..."
netsh advfirewall firewall add rule name="DotnetX86App" dir=in action=allow protocol=TCP localport=$AppPort | Out-Null
OK "Firewall port $AppPort open"

# -- 3. Register Windows Service via sc.exe -----------------------------------
Log "Step 3: Registering 32-bit Windows service $ServiceName..."
sc.exe stop   $ServiceName 2>$null
sc.exe delete $ServiceName 2>$null
Start-Sleep -Seconds 2

$result = sc.exe create $ServiceName `
    binPath= "`"$ExePath`"" `
    DisplayName= "Datadog .NET x86 (32-bit) SSI Demo" `
    start= auto
if ($LASTEXITCODE -ne 0) { FAIL "sc.exe create failed: $result" }
OK "Service $ServiceName registered"

# -- 4. Set DD_ env vars in registry ------------------------------------------
Log "Step 4: Setting DD_ environment variables..."
New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName" `
    -Name "Environment" -PropertyType MultiString -Force -Value @(
        "DD_SERVICE=dotnet-x86-app",
        "DD_ENV=demo",
        "DD_VERSION=1.0"
    ) | Out-Null
OK "DD_ env vars set"

# -- 5. Install Datadog Agent + SSI -------------------------------------------
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
    OK "Datadog Agent installed (ddinjector_x86.dll will be used for 32-bit process)"
}

# -- 6. Start service ---------------------------------------------------------
Log "Step 6: Starting 32-bit service $ServiceName..."
Start-Service -Name $ServiceName
Start-Sleep -Seconds 5

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq "Running") {
    OK "32-bit service running — ddinjector_x86.dll should inject into DotnetX86App.exe"
} else {
    FAIL "Service failed to start"
}

if ($Verify) {
    & "$ScriptDir\verify.ps1" -TargetHost "localhost" -DDApiKey $DDApiKey -DDSite $DDSite
}

Log "=== Setup complete ==="
