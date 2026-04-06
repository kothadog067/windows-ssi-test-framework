<#
.SYNOPSIS
    Removes the dd-dotnet-iis application, IIS site, and app pool.

.DESCRIPTION
    Safely stops and removes:
    - IIS Site: DDIisSite
    - IIS Application Pool: DDIisAppPool
    - Published files: C:\inetpub\dd-iis-app

    Always exits 0.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "SilentlyContinue"

function Write-Step { param([string]$Msg) Write-Host "`n==> $Msg" -ForegroundColor Cyan }
function Write-OK   { param([string]$Msg) Write-Host "    [OK] $Msg" -ForegroundColor Green }

$SiteName    = "DDIisSite"
$AppPoolName = "DDIisAppPool"
$PublishPath = "C:\inetpub\dd-iis-app"

# ---------------------------------------------------------------------------
# 1. Stop and remove IIS site
# ---------------------------------------------------------------------------
Write-Step "Removing IIS Site: $SiteName"
try {
    Import-Module WebAdministration -ErrorAction Stop
    $site = Get-WebSite -Name $SiteName -ErrorAction SilentlyContinue
    if ($site) {
        if ($site.State -eq "Started") {
            Stop-WebSite -Name $SiteName -ErrorAction SilentlyContinue
        }
        Remove-WebSite -Name $SiteName -ErrorAction SilentlyContinue
        Write-OK "Site removed"
    } else {
        Write-OK "Site not found; nothing to remove"
    }
} catch {
    Write-Host "    Warning: $_"
}

# ---------------------------------------------------------------------------
# 2. Stop and remove application pool
# ---------------------------------------------------------------------------
Write-Step "Removing IIS App Pool: $AppPoolName"
try {
    $pool = Get-WebAppPoolState -Name $AppPoolName -ErrorAction SilentlyContinue
    if ($pool) {
        if ($pool.Value -eq "Started") {
            Stop-WebAppPool -Name $AppPoolName -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }
        Remove-WebAppPool -Name $AppPoolName -ErrorAction SilentlyContinue
        Write-OK "App pool removed"
    } else {
        Write-OK "App pool not found; nothing to remove"
    }
} catch {
    Write-Host "    Warning: $_"
}

# ---------------------------------------------------------------------------
# 3. Remove published files
# ---------------------------------------------------------------------------
Write-Step "Removing published files: $PublishPath"
if (Test-Path $PublishPath) {
    Remove-Item -Recurse -Force $PublishPath -ErrorAction SilentlyContinue
    Write-OK "Files removed"
} else {
    Write-OK "Directory not found; nothing to remove"
}

Write-Host "`n[DONE] dd-dotnet-iis teardown complete." -ForegroundColor Green
exit 0
