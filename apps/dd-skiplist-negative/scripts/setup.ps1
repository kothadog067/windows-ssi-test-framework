# =============================================================================
#  dd-skiplist-negative — Setup Script
#  Negative test: verifies that skip-listed processes (from default-skiplist.yaml)
#  are never instrumented by ddinjector, even when SSI is enabled.
#
#  No service to install — the test uses the already-running DD agent processes.
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
Log "=== dd-skiplist-negative — Setup ==="

# ── Install Datadog Agent + SSI (required: we need agent running to test skip list) ──
if ($InstallAgent) {
    if (-not $DDApiKey) { FAIL "-InstallAgent requires -DDApiKey or DD_API_KEY env var" }

    Log "Installing Datadog Agent (with SSI)..."
    $msiArgs = "/qn /i `"https://windows-agent.datadoghq.com/datadog-agent-7-latest.amd64.msi`"" +
               " /log C:\Windows\SystemTemp\install-datadog.log" +
               " APIKEY=`"$DDApiKey`" SITE=`"$DDSite`"" +
               " DD_APM_INSTRUMENTATION_ENABLED=`"host`"" +
               " DD_APM_INSTRUMENTATION_LIBRARIES=`"dotnet:3,java:1`""
    $p = Start-Process -Wait -PassThru msiexec -ArgumentList $msiArgs
    if ($p.ExitCode -ne 0) { FAIL "msiexec failed ($($p.ExitCode)) — check C:\Windows\SystemTemp\install-datadog.log" }
    OK "Datadog Agent installed with SSI"
    Start-Sleep -Seconds 10  # let ddinjector settle
} else {
    # Verify agent is already running
    $agentSvc = Get-Service -Name "datadogagent" -ErrorAction SilentlyContinue
    if (-not $agentSvc -or $agentSvc.Status -ne "Running") {
        FAIL "Datadog Agent must be running. Use -InstallAgent to install, or start it manually."
    }
    OK "Datadog Agent already running"
}

# ── Start a simple test process that IS on the skip list ─────────────────────
# We'll use notepad.exe (also on the skip list) as a canary to ensure the
# skip list check is enforced
Log "Starting notepad.exe as a skip-listed canary process..."
Start-Process notepad.exe -WindowStyle Hidden -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3
OK "Canary process started"

Log "Setup complete — run verify.ps1 to check skip list enforcement"

if ($Verify) {
    & "$ScriptDir\verify.ps1" -TargetHost "localhost"
}

Log "=== Setup complete ==="
