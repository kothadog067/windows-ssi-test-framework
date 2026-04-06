<#
.SYNOPSIS
    Installs and configures the dd-dotnet-iis application on a Windows host.

.DESCRIPTION
    - Installs Chocolatey (if absent)
    - Installs IIS + ASP.NET Core Hosting Bundle via Chocolatey
    - Publishes the ASP.NET Core app to C:\inetpub\dd-iis-app
    - Creates an IIS application pool and site
    - Sets Datadog environment variables on the application pool
    - Optionally installs the Datadog Agent

.PARAMETER DDApiKey
    Datadog API key. Required when -InstallAgent is specified.

.PARAMETER DDSite
    Datadog intake site (e.g. datadoghq.com). Defaults to datadoghq.com.

.PARAMETER InstallAgent
    When present, downloads and installs the Datadog Windows Agent MSI.

.PARAMETER Verify
    When present, runs verify.ps1 at the end of setup.

.EXAMPLE
    .\setup.ps1 -DDApiKey "abc123" -DDSite "datadoghq.com" -InstallAgent -Verify
#>
[CmdletBinding()]
param(
    [string]$DDApiKey  = "",
    [string]$DDSite    = "datadoghq.com",
    [switch]$InstallAgent,
    [switch]$Verify
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Step { param([string]$Msg) Write-Host "`n==> $Msg" -ForegroundColor Cyan }
function Write-OK   { param([string]$Msg) Write-Host "    [OK] $Msg" -ForegroundColor Green }
function Write-Fail { param([string]$Msg) Write-Host "    [FAIL] $Msg" -ForegroundColor Red }

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
$AppName       = "dd-iis-app"
$AppPoolName   = "DDIisAppPool"
$SiteName      = "DDIisSite"
$PublishPath   = "C:\inetpub\$AppName"
$ScriptDir     = $PSScriptRoot
$AppDir        = Join-Path $ScriptDir "..\app\dotnet-iis-app"
$LogDir        = Join-Path $PublishPath "logs"

# ---------------------------------------------------------------------------
Assert-Admin
Write-Step "Starting dd-dotnet-iis setup"

# ---------------------------------------------------------------------------
# 1. Chocolatey
# ---------------------------------------------------------------------------
Ensure-Chocolatey

# ---------------------------------------------------------------------------
# 2. IIS Windows Features
# ---------------------------------------------------------------------------
Write-Step "Enabling IIS Windows Features"
$features = @(
    "IIS-WebServerRole",
    "IIS-WebServer",
    "IIS-CommonHttpFeatures",
    "IIS-HttpErrors",
    "IIS-ApplicationDevelopment",
    "IIS-HealthAndDiagnostics",
    "IIS-HttpLogging",
    "IIS-Security",
    "IIS-RequestFiltering",
    "IIS-Performance",
    "IIS-WebServerManagementTools",
    "IIS-ManagementConsole",
    "NetFx4Extended-ASPNET45",
    "IIS-NetFxExtensibility45",
    "IIS-ASPNET45"
)
foreach ($f in $features) {
    Enable-WindowsOptionalFeature -Online -FeatureName $f -All -NoRestart -ErrorAction SilentlyContinue | Out-Null
}
Write-OK "IIS features enabled"

# ---------------------------------------------------------------------------
# 3. ASP.NET Core Hosting Bundle
# ---------------------------------------------------------------------------
Write-Step "Installing ASP.NET Core Hosting Bundle (dotnet-windowshosting)"
choco install dotnet-windowshosting --version 8.0.0 -y --no-progress 2>&1 | Out-Null
# Refresh IIS after hosting bundle install
if (Get-Command iisreset -ErrorAction SilentlyContinue) { iisreset /noforce | Out-Null }
Write-OK "Hosting Bundle installed"

# ---------------------------------------------------------------------------
# 4. Publish app
# ---------------------------------------------------------------------------
Write-Step "Publishing ASP.NET Core app to $PublishPath"
if (-not (Test-Path $AppDir)) {
    throw "App source not found at: $AppDir"
}
New-Item -ItemType Directory -Force -Path $PublishPath | Out-Null
New-Item -ItemType Directory -Force -Path $LogDir      | Out-Null

Push-Location $AppDir
dotnet publish IisApp.csproj `
    --configuration Release `
    --output $PublishPath `
    --no-self-contained `
    --runtime win-x64
Pop-Location
Write-OK "Published to $PublishPath"

# ---------------------------------------------------------------------------
# 5. IIS Application Pool
# ---------------------------------------------------------------------------
Write-Step "Configuring IIS Application Pool: $AppPoolName"
Import-Module WebAdministration -ErrorAction Stop

if (Test-Path "IIS:\AppPools\$AppPoolName") {
    Write-Host "    App pool already exists; reconfiguring."
    Remove-WebAppPool -Name $AppPoolName
}

New-WebAppPool -Name $AppPoolName
Set-ItemProperty "IIS:\AppPools\$AppPoolName" managedRuntimeVersion ""
Set-ItemProperty "IIS:\AppPools\$AppPoolName" processModel.identityType 4   # ApplicationPoolIdentity
Set-ItemProperty "IIS:\AppPools\$AppPoolName" startMode 1                    # AlwaysRunning
Set-ItemProperty "IIS:\AppPools\$AppPoolName" autoStart $true
Write-OK "App pool created"

# ---------------------------------------------------------------------------
# 6. Set Datadog env vars on the app pool
# ---------------------------------------------------------------------------
Write-Step "Setting DD_ environment variables on app pool"
$envPath = "IIS:\AppPools\$AppPoolName\environmentVariables"

function Set-AppPoolEnv {
    param([string]$Name, [string]$Value)
    $existing = Get-WebConfiguration -PSPath $envPath | Where-Object { $_.name -eq $Name }
    if ($existing) {
        Set-WebConfigurationProperty -PSPath $envPath -Filter "add[@name='$Name']" -Name "value" -Value $Value
    } else {
        Add-WebConfiguration -PSPath $envPath -Value @{name=$Name; value=$Value}
    }
}

Set-AppPoolEnv "DD_SERVICE" "dd-iis-app"
Set-AppPoolEnv "DD_ENV"     "demo"
Set-AppPoolEnv "DD_VERSION" "1.0.0"
if ($DDApiKey) { Set-AppPoolEnv "DD_API_KEY" $DDApiKey }
if ($DDSite)   { Set-AppPoolEnv "DD_SITE"    $DDSite   }
Write-OK "DD_ env vars set on app pool"

# ---------------------------------------------------------------------------
# 7. IIS Site
# ---------------------------------------------------------------------------
Write-Step "Creating IIS Site: $SiteName"
if (Get-WebSite -Name $SiteName -ErrorAction SilentlyContinue) {
    Remove-WebSite -Name $SiteName
}

New-WebSite -Name $SiteName `
            -PhysicalPath $PublishPath `
            -ApplicationPool $AppPoolName `
            -Port 80 `
            -Force | Out-Null

# Add additional binding on 8082
New-WebBinding -Name $SiteName -Protocol "http" -Port 8082 -IPAddress "*"

Start-WebSite -Name $SiteName
Write-OK "IIS site created and started on ports 80 and 8082"

# Grant IIS_IUSRS read access to publish directory
icacls $PublishPath /grant "IIS_IUSRS:(OI)(CI)R" /T /Q

# ---------------------------------------------------------------------------
# 8. Optional: Datadog Agent
# ---------------------------------------------------------------------------
if ($InstallAgent) {
    if (-not $DDApiKey) { throw "-DDApiKey is required when -InstallAgent is specified." }
    Write-Step "Installing Datadog Agent (with SSI)"
    $msiArgs = "/qn /i `"https://windows-agent.datadoghq.com/datadog-agent-7-latest.amd64.msi`"" +
               " /log C:\Windows\SystemTemp\install-datadog.log" +
               " APIKEY=`"$DDApiKey`" SITE=`"$DDSite`"" +
               " DD_APM_INSTRUMENTATION_ENABLED=`"host`"" +
               " DD_APM_INSTRUMENTATION_LIBRARIES=`"dotnet:3`""
    $p = Start-Process -Wait -PassThru msiexec -ArgumentList $msiArgs
    if ($p.ExitCode -ne 0) { FAIL "msiexec failed ($($p.ExitCode)) — check C:\Windows\SystemTemp\install-datadog.log" }
    Write-OK "Datadog Agent installed with SSI"
}

# ---------------------------------------------------------------------------
# 9. Optional verify
# ---------------------------------------------------------------------------
if ($Verify) {
    Write-Step "Running verify.ps1"
    & (Join-Path $ScriptDir "verify.ps1") -TargetHost "localhost" -DDApiKey $DDApiKey -DDSite $DDSite
}

Write-Host "`n[DONE] dd-dotnet-iis setup complete." -ForegroundColor Green
