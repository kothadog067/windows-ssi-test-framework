<#
.SYNOPSIS
    Stops, deletes, and cleans up the DDWorker2019Svc Windows Service.

.DESCRIPTION
    Removes:
    - Windows Service: DDWorker2019Svc  (sc stop + sc delete)
    - Registry env vars: HKLM:\SYSTEM\CurrentControlSet\Services\DDWorker2019Svc\Environment
    - Installation directory: C:\dd-worker-2019-svc
    - Firewall rule: DDWorker2019Svc-HTTP-8084

    Always exits 0.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "SilentlyContinue"

function Write-Step { param([string]$Msg) Write-Host "`n==> $Msg" -ForegroundColor Cyan }
function Write-OK   { param([string]$Msg) Write-Host "    [OK] $Msg" -ForegroundColor Green }

$ServiceName = "DDWorker2019Svc"
$InstallPath = "C:\dd-worker-2019-svc"
$RegSvcPath  = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
$FirewallRule= "DDWorker2019Svc-HTTP-8084"

# ---------------------------------------------------------------------------
# 1. Stop the service
# ---------------------------------------------------------------------------
Write-Step "Stopping service: $ServiceName"
$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc) {
    if ($svc.Status -ne "Stopped") {
        sc.exe stop $ServiceName | Out-Null
        $deadline = (Get-Date).AddSeconds(15)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 2
            $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
            if ($svc.Status -eq "Stopped") { break }
        }
    }
    Write-OK "Service stopped (final state: $($svc.Status))"
} else {
    Write-OK "Service not found; nothing to stop"
}

# ---------------------------------------------------------------------------
# 2. Delete the service
# ---------------------------------------------------------------------------
Write-Step "Deleting service: $ServiceName"
sc.exe delete $ServiceName 2>&1 | Out-Null
Write-OK "sc delete issued"

# ---------------------------------------------------------------------------
# 3. Clean registry environment block
# ---------------------------------------------------------------------------
Write-Step "Removing registry env vars"
if (Test-Path $RegSvcPath) {
    try {
        Remove-ItemProperty -Path $RegSvcPath -Name "Environment" -ErrorAction SilentlyContinue
        Write-OK "Registry Environment value removed"
    } catch {
        Write-Host "    Warning: $_"
    }
} else {
    Write-OK "Registry key not found; nothing to remove"
}

# ---------------------------------------------------------------------------
# 4. Remove installation files
# ---------------------------------------------------------------------------
Write-Step "Removing installation directory: $InstallPath"
if (Test-Path $InstallPath) {
    Remove-Item -Recurse -Force $InstallPath -ErrorAction SilentlyContinue
    Write-OK "Directory removed"
} else {
    Write-OK "Directory not found; nothing to remove"
}

# ---------------------------------------------------------------------------
# 5. Remove firewall rule
# ---------------------------------------------------------------------------
Write-Step "Removing firewall rule: $FirewallRule"
Remove-NetFirewallRule -DisplayName $FirewallRule -ErrorAction SilentlyContinue
Write-OK "Firewall rule removed"

Write-Host "`n[DONE] dd-win-server-2019 teardown complete." -ForegroundColor Green
exit 0
