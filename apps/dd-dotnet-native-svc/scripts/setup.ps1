<#
.SYNOPSIS
    Builds, installs, and starts the dd-dotnet-native-svc Windows Service.

.DESCRIPTION
    - Publishes the .NET 8 Worker Service as a self-contained win-x64 executable
    - Registers the service with sc.exe (NOT NSSM, NOT IIS)
    - Injects DD_SERVICE / DD_ENV / DD_VERSION into the service's registry
      environment block (HKLM:\SYSTEM\CurrentControlSet\Services\DDWorkerSvc\Environment)
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

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
$ServiceName  = "DDWorkerSvc"
$DisplayName  = "Datadog .NET Worker Service Demo"
$InstallPath  = "C:\dd-worker-svc"
$ExePath      = Join-Path $InstallPath "WorkerSvc.exe"
$ScriptDir    = $PSScriptRoot
$AppDir       = Join-Path $ScriptDir "..\app\dotnet-worker-svc"
$RegEnvPath   = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName\Environment"

Assert-Admin
Write-Step "Starting dd-dotnet-native-svc setup"

# ---------------------------------------------------------------------------
# 1. Verify .NET 8 SDK
# ---------------------------------------------------------------------------
Write-Step "Checking .NET SDK"
$dotnetVer = dotnet --version 2>&1
if ($LASTEXITCODE -ne 0) {
    throw ".NET SDK not found. Install .NET 8 SDK before running this script."
}
Write-OK ".NET SDK version: $dotnetVer"

# ---------------------------------------------------------------------------
# 2. Publish self-contained win-x64 executable
# ---------------------------------------------------------------------------
Write-Step "Publishing self-contained executable to $InstallPath"
New-Item -ItemType Directory -Force -Path $InstallPath | Out-Null

Push-Location $AppDir
dotnet publish WorkerService.csproj `
    --configuration Release `
    --output $InstallPath `
    --self-contained true `
    --runtime win-x64 `
    -p:PublishReadyToRun=true
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed" }
Pop-Location
Write-OK "Published to $InstallPath"

if (-not (Test-Path $ExePath)) {
    throw "Expected executable not found: $ExePath"
}

# ---------------------------------------------------------------------------
# 3. Remove existing service if present
# ---------------------------------------------------------------------------
$existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Step "Removing existing service: $ServiceName"
    if ($existing.Status -ne "Stopped") {
        sc.exe stop $ServiceName | Out-Null
        Start-Sleep -Seconds 5
    }
    sc.exe delete $ServiceName | Out-Null
    Start-Sleep -Seconds 2
    Write-OK "Existing service removed"
}

# ---------------------------------------------------------------------------
# 4. Register service with sc.exe
# ---------------------------------------------------------------------------
Write-Step "Registering Windows Service: $ServiceName"
sc.exe create $ServiceName `
    binPath= "`"$ExePath`"" `
    DisplayName= "$DisplayName" `
    start= auto
if ($LASTEXITCODE -ne 0) { throw "sc.exe create failed with exit code $LASTEXITCODE" }
Write-OK "Service registered"

sc.exe description $ServiceName "Datadog .NET Worker Service SSI test: HttpListener on :8084 + periodic compute work." | Out-Null

# ---------------------------------------------------------------------------
# 5. Set Datadog environment variables via registry
#    The SCM reads the REG_MULTI_SZ value "Environment" under the service key
#    and injects each "NAME=VALUE" string into the service process environment.
# ---------------------------------------------------------------------------
Write-Step "Writing DD_ env vars to registry: $RegEnvPath"

# Build the multi-string array
$envEntries = @(
    "DD_SERVICE=dd-worker-svc",
    "DD_ENV=demo",
    "DD_VERSION=1.0.0"
)
if ($DDApiKey) { $envEntries += "DD_API_KEY=$DDApiKey" }
if ($DDSite)   { $envEntries += "DD_SITE=$DDSite"      }

# The "Environment" key must exist under the service key
if (-not (Test-Path $RegEnvPath)) {
    New-Item -Path $RegEnvPath -Force | Out-Null
}
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName" `
                 -Name "Environment" `
                 -Value $envEntries `
                 -Type MultiString
Write-OK "Registry env vars set"

# ---------------------------------------------------------------------------
# 6. Configure service failure actions (restart on crash)
# ---------------------------------------------------------------------------
sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/10000/restart/30000 | Out-Null

# ---------------------------------------------------------------------------
# 7. Start the service
# ---------------------------------------------------------------------------
Write-Step "Starting service: $ServiceName"
sc.exe start $ServiceName | Out-Null
Start-Sleep -Seconds 6

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq "Running") {
    Write-OK "Service is Running"
} else {
    Write-Host "    Warning: service may not have started yet. Status: $($svc?.Status)"
}

# ---------------------------------------------------------------------------
# 8. Open Windows Firewall for port 8084
# ---------------------------------------------------------------------------
Write-Step "Opening firewall port 8084"
$ruleName = "DDWorkerSvc-HTTP-8084"
Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName $ruleName `
                   -Direction Inbound `
                   -Protocol TCP `
                   -LocalPort 8084 `
                   -Action Allow | Out-Null
Write-OK "Firewall rule created"

# ---------------------------------------------------------------------------
# 9. Optional: Datadog Agent
# ---------------------------------------------------------------------------
if ($InstallAgent) {
    if (-not $DDApiKey) { throw "-DDApiKey is required when -InstallAgent is specified." }
    Write-Step "Installing Datadog Agent"
    $msiUrl  = "https://s3.amazonaws.com/ddagent-windows-stable/datadog-agent-7-latest.amd64.msi"
    $msiPath = "$env:TEMP\datadog-agent.msi"
    Write-Host "    Downloading..."
    (New-Object System.Net.WebClient).DownloadFile($msiUrl, $msiPath)
    $msiArgs = "/qn /i `"$msiPath`" APIKEY=`"$DDApiKey`" SITE=`"$DDSite`" TAGS=`"env:demo`""
    Start-Process msiexec.exe -ArgumentList $msiArgs -Wait -NoNewWindow
    Remove-Item $msiPath -Force -ErrorAction SilentlyContinue
    Write-OK "Datadog Agent installed"
}

# ---------------------------------------------------------------------------
# 10. Optional verify
# ---------------------------------------------------------------------------
if ($Verify) {
    Write-Step "Running verify.ps1"
    & (Join-Path $ScriptDir "verify.ps1") -TargetHost "localhost" -DDApiKey $DDApiKey -DDSite $DDSite
}

Write-Host "`n[DONE] dd-dotnet-native-svc setup complete." -ForegroundColor Green
