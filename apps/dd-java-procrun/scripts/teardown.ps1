<#
.SYNOPSIS
    Stops and removes the JavaProcrunSvc Windows Service and all associated files.

.DESCRIPTION
    Safely removes:
    - Windows Service: JavaProcrunSvc  (stopped via prunsrv.exe //SS//, deleted via //DS//)
    - Installation directory: C:\dd-java-procrun

    Always exits 0.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "SilentlyContinue"

function Write-Step { param([string]$Msg) Write-Host "`n==> $Msg" -ForegroundColor Cyan }
function Write-OK   { param([string]$Msg) Write-Host "    [OK] $Msg" -ForegroundColor Green }

$ServiceName  = "JavaProcrunSvc"
$InstallRoot  = "C:\dd-java-procrun"
$PrunsrvExe   = Join-Path $InstallRoot "daemon\prunsrv.exe"

# ---------------------------------------------------------------------------
# 1. Stop the service
# ---------------------------------------------------------------------------
Write-Step "Stopping service: $ServiceName"
$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc) {
    if ($svc.Status -ne "Stopped") {
        if (Test-Path $PrunsrvExe) {
            & $PrunsrvExe //SS//$ServiceName 2>&1 | Out-Null
        } else {
            Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Seconds 5
    }
    Write-OK "Service stopped"
} else {
    Write-OK "Service not found; nothing to stop"
}

# ---------------------------------------------------------------------------
# 2. Delete the service
# ---------------------------------------------------------------------------
Write-Step "Deleting service: $ServiceName"
if (Test-Path $PrunsrvExe) {
    & $PrunsrvExe //DS//$ServiceName 2>&1 | Out-Null
} else {
    sc.exe delete $ServiceName 2>&1 | Out-Null
}
Write-OK "Service deleted"

# ---------------------------------------------------------------------------
# 3. Remove installation files
# ---------------------------------------------------------------------------
Write-Step "Removing installation directory: $InstallRoot"
if (Test-Path $InstallRoot) {
    Remove-Item -Recurse -Force $InstallRoot -ErrorAction SilentlyContinue
    Write-OK "Directory removed"
} else {
    Write-OK "Directory not found; nothing to remove"
}

Write-Host "`n[DONE] dd-java-procrun teardown complete." -ForegroundColor Green
exit 0
