# =============================================================================
#  dd-dotnet-selfcontained — Setup Script
#  Tests SSI injection into a .NET 8 self-contained single-file executable.
#  The ddinjector dotnet.c detects self-contained apps via PE .data bundle
#  signature (BUNDLESIG marker in the PE file).
#  Process name: DotnetSelfContained.exe, Port: 8086
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
Log "=== dd-dotnet-selfcontained — Setup ==="

$ServiceName = "DDSelfContainedSvc"
$InstallPath = "C:\dd-selfcontained"
$ExePath     = "$InstallPath\DotnetSelfContained.exe"
$SourceDir   = Join-Path $AppDir "app\self-contained-app"
$AppPort     = 8086

# ── 1. Publish as self-contained single-file win-x64 ──────────────────────────
Log "Step 1: Publishing .NET 8 self-contained single-file app..."
New-Item -ItemType Directory -Force -Path $InstallPath | Out-Null

Push-Location $SourceDir
dotnet publish SelfContainedApp.csproj `
    --configuration Release `
    --runtime win-x64 `
    --self-contained true `
    -p:PublishSingleFile=true `
    -p:IncludeNativeLibrariesForSelfExtract=true `
    --output $InstallPath
Pop-Location

if (-not (Test-Path $ExePath)) {
    FAIL "Build failed: $ExePath not found after publish"
}
OK "Published self-contained single-file to $ExePath"

# ── 2. Open firewall ───────────────────────────────────────────────────────────
Log "Step 2: Opening firewall port $AppPort..."
netsh advfirewall firewall add rule name="DotnetSelfContained" dir=in action=allow protocol=TCP localport=$AppPort | Out-Null
OK "Firewall port $AppPort open"

# ── 3. Register Windows Service via sc.exe ────────────────────────────────────
Log "Step 3: Registering Windows service $ServiceName..."
sc.exe stop  $ServiceName 2>$null
sc.exe delete $ServiceName 2>$null
Start-Sleep -Seconds 2

$result = sc.exe create $ServiceName `
    binPath= "`"$ExePath`"" `
    DisplayName= "Datadog .NET Self-Contained SSI Demo" `
    start= auto
if ($LASTEXITCODE -ne 0) { FAIL "sc.exe create failed: $result" }
OK "Service $ServiceName registered"

# ── 4. Set DD_ env vars in registry ───────────────────────────────────────────
Log "Step 4: Setting DD_ environment variables in service registry..."
$regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
New-ItemProperty -Path $regPath -Name "Environment" -PropertyType MultiString -Force -Value @(
    "DD_SERVICE=dotnet-selfcontained-app",
    "DD_ENV=demo",
    "DD_VERSION=1.0"
) | Out-Null
OK "DD_ env vars set"

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

# ── 6. Start the service ───────────────────────────────────────────────────────
Log "Step 6: Starting service $ServiceName..."
Start-Service -Name $ServiceName
Start-Sleep -Seconds 5

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq "Running") {
    OK "Service $ServiceName is running — SSI injection triggered into DotnetSelfContained.exe"
} else {
    FAIL "Service $ServiceName failed to start"
}

if ($Verify) {
    & "$ScriptDir\verify.ps1" -TargetHost "localhost" -DDApiKey $DDApiKey -DDSite $DDSite
}

Log "=== Setup complete ==="
