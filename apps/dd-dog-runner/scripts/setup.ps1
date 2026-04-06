# =============================================================================
#  DD Dog Runner — Setup Script
#  Standard interface: setup.ps1 [-DDApiKey <key>] [-DDSite <site>]
#                                  [-InstallAgent] [-Verify]
#  Exit 0 = success, Exit 1 = failure
#  Run as Administrator
# =============================================================================

param(
    [string]$DDApiKey     = $env:DD_API_KEY,
    [string]$DDSite       = $(if ($env:DD_SITE) { $env:DD_SITE } else { "datadoghq.com" }),
    [switch]$InstallAgent,
    [switch]$Verify
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

$AppRoot          = "C:\dd-demo"
$JavaPath         = "$AppRoot\java-leaderboard"
$DotNetPath       = "$AppRoot\dotnet-game-server"
$ScriptDir        = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoAppDir       = Split-Path -Parent $ScriptDir   # apps/dd-dog-runner/

function Log($m)  { Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $m" -ForegroundColor Cyan }
function OK($m)   { Write-Host "  [OK] $m"   -ForegroundColor Green }
function FAIL($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; exit 1 }

Log "=== DD Dog Runner — Setup ==="

# ── 1. Install Chocolatey ─────────────────────────────────────────────────────
if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Log "Installing Chocolatey..."
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    $env:PATH += ";C:\ProgramData\chocolatey\bin"
    OK "Chocolatey installed"
} else { OK "Chocolatey already present" }

# ── 2. Install Java 21 ────────────────────────────────────────────────────────
if (-not (Get-Command java -ErrorAction SilentlyContinue)) {
    Log "Installing Java 21 (Eclipse Temurin)..."
    choco install temurin21 -y --no-progress
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH","User")
    OK "Java installed"
} else { OK "Java already present" }

# ── 3. Install .NET 8 SDK ─────────────────────────────────────────────────────
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    Log "Installing .NET 8 SDK..."
    choco install dotnet-8.0-sdk -y --no-progress
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH","User")
    OK ".NET installed"
} else { OK ".NET already present" }

# ── 4. Install NSSM ───────────────────────────────────────────────────────────
if (-not (Get-Command nssm -ErrorAction SilentlyContinue)) {
    Log "Installing NSSM..."
    choco install nssm -y --no-progress
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH","User")
    OK "NSSM installed"
} else { OK "NSSM already present" }

# ── 5. Create directories ─────────────────────────────────────────────────────
Log "Creating directories..."
foreach ($d in @($JavaPath, $DotNetPath, "$DotNetPath\wwwroot", "$JavaPath\logs", "$DotNetPath\logs")) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}
OK "Directories created"

# ── 6. Copy source files ──────────────────────────────────────────────────────
Log "Copying source files..."
Copy-Item "$RepoAppDir\app\java-leaderboard\LeaderboardServer.java" $JavaPath -Force
Copy-Item "$RepoAppDir\app\dotnet-game-server\DinoGameServer.csproj" $DotNetPath -Force
Copy-Item "$RepoAppDir\app\dotnet-game-server\Program.cs" $DotNetPath -Force
Copy-Item "$RepoAppDir\app\dotnet-game-server\wwwroot\index.html" "$DotNetPath\wwwroot\" -Force
OK "Source files copied"

# ── 7. Compile Java ───────────────────────────────────────────────────────────
Log "Compiling Java Leaderboard..."
Push-Location $JavaPath
javac LeaderboardServer.java
if ($LASTEXITCODE -ne 0) { FAIL "Java compilation failed" }
OK "Java compiled"
Pop-Location

# ── 8. Build .NET ─────────────────────────────────────────────────────────────
Log "Building .NET Game Server..."
Push-Location $DotNetPath
dotnet publish -c Release -o bin\publish --self-contained false
if ($LASTEXITCODE -ne 0) { FAIL ".NET build failed" }
Copy-Item "wwwroot" "bin\publish\wwwroot" -Recurse -Force
OK ".NET built"
Pop-Location

# ── 9. Firewall ───────────────────────────────────────────────────────────────
Log "Opening firewall ports..."
netsh advfirewall firewall add rule name="DD Game Server 8080" dir=in action=allow protocol=TCP localport=8080 | Out-Null
netsh advfirewall firewall add rule name="DD Leaderboard 8081" dir=in action=allow protocol=TCP localport=8081 | Out-Null
OK "Firewall rules added"

# ── 10. Remove old services if they exist ────────────────────────────────────
foreach ($svc in @("DDGameServer","DDLeaderboard")) {
    if (Get-Service -Name $svc -ErrorAction SilentlyContinue) {
        Log "Removing old $svc service..."
        Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
        nssm remove $svc confirm
    }
}

# ── 11. Register DDGameServer (.NET) ─────────────────────────────────────────
Log "Registering DDGameServer (.NET)..."
nssm install DDGameServer "dotnet" "$DotNetPath\bin\publish\DinoGameServer.dll"
nssm set DDGameServer AppDirectory "$DotNetPath\bin\publish"
nssm set DDGameServer DisplayName "DD Demo - Game Server (.NET)"
nssm set DDGameServer Description "Dino Runner game server - .NET demo for Datadog SSI"
nssm set DDGameServer AppStdout "$DotNetPath\logs\game-server.log"
nssm set DDGameServer AppStderr "$DotNetPath\logs\game-server-error.log"
nssm set DDGameServer Start SERVICE_AUTO_START
nssm set DDGameServer AppEnvironmentExtra "DD_SERVICE=dd-game-server" "DD_ENV=demo" "DD_VERSION=1.0.0"
OK "DDGameServer registered"

# ── 12. Register DDLeaderboard (Java) ────────────────────────────────────────
Log "Registering DDLeaderboard (Java)..."
$javaExe = (Get-Command java).Source
nssm install DDLeaderboard $javaExe "-cp . LeaderboardServer"
nssm set DDLeaderboard AppDirectory $JavaPath
nssm set DDLeaderboard DisplayName "DD Demo - Leaderboard (Java)"
nssm set DDLeaderboard Description "Leaderboard API - Java demo for Datadog SSI"
nssm set DDLeaderboard AppStdout "$JavaPath\logs\leaderboard.log"
nssm set DDLeaderboard AppStderr "$JavaPath\logs\leaderboard-error.log"
nssm set DDLeaderboard Start SERVICE_AUTO_START
nssm set DDLeaderboard AppEnvironmentExtra "DD_SERVICE=dd-leaderboard" "DD_ENV=demo" "DD_VERSION=1.0.0"
OK "DDLeaderboard registered"

# ── 13. Install Datadog Agent + SSI ──────────────────────────────────────────
if ($InstallAgent) {
    if (-not $DDApiKey) { FAIL "-InstallAgent requires -DDApiKey or DD_API_KEY env var" }

    Log "Installing Datadog Agent (with SSI)..."
    $msiUrl  = "https://s3.amazonaws.com/ddagent-windows-stable/datadog-agent-7-latest.amd64.msi"
    $msiPath = "$env:TEMP\datadog-agent.msi"
    Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath

    $msiArgs = @(
        "/i", $msiPath,
        "APIKEY=$DDApiKey",
        "SITE=$DDSite",
        "HOSTNAME_FQDN_ENABLED=true",
        "/qn", "/l*v", "$env:TEMP\dd-agent-install.log"
    )
    Start-Process msiexec.exe -Wait -ArgumentList $msiArgs
    OK "Datadog Agent installed"

    # Enable Windows Host-Wide SSI in datadog.yaml
    $ddYaml = "C:\ProgramData\Datadog\datadog.yaml"
    if (Test-Path $ddYaml) {
        $content = Get-Content $ddYaml -Raw
        if ($content -notmatch "windows_single_step_instrumentation") {
            Add-Content $ddYaml "`r`n# Windows Host-Wide SSI`r`napm_config:`r`n  windows_single_step_instrumentation:`r`n    enabled: true"
            OK "SSI enabled in datadog.yaml"
        } else {
            OK "SSI already present in datadog.yaml"
        }
    }

    Restart-Service -Name "datadogagent" -ErrorAction SilentlyContinue
    OK "Datadog Agent restarted"
}

# ── 14. Start services ────────────────────────────────────────────────────────
Log "Starting services..."
Start-Service DDLeaderboard
Start-Service DDGameServer
Start-Sleep -Seconds 5

$g = Get-Service DDGameServer
$l = Get-Service DDLeaderboard
if ($g.Status -ne "Running") { FAIL "DDGameServer failed to start — check $DotNetPath\logs\game-server-error.log" }
if ($l.Status -ne "Running") { FAIL "DDLeaderboard failed to start — check $JavaPath\logs\leaderboard-error.log" }
OK "DDGameServer RUNNING"
OK "DDLeaderboard RUNNING"

# ── 15. Restart services after agent install (triggers SSI injection) ─────────
if ($InstallAgent) {
    Log "Restarting services to trigger SSI injection..."
    Restart-Service DDGameServer
    Restart-Service DDLeaderboard
    Start-Sleep -Seconds 5
    OK "Services restarted — SSI injection triggered"
}

# ── 16. Optional verify ───────────────────────────────────────────────────────
if ($Verify) {
    & "$ScriptDir\verify.ps1" -Host "localhost"
}

# ── Output ────────────────────────────────────────────────────────────────────
try {
    $ip = (Invoke-WebRequest -Uri "http://169.254.169.254/latest/meta-data/public-ipv4" -TimeoutSec 3).Content
} catch { $ip = "localhost" }

Write-Host ""
Write-Host "=============================================" -ForegroundColor Green
Write-Host "  SETUP COMPLETE: dd-dog-runner" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
Write-Host "  Game:        http://${ip}:8080" -ForegroundColor White
Write-Host "  Leaderboard: http://${ip}:8081/leaderboard" -ForegroundColor White
Write-Host "  Health:      http://${ip}:8081/health" -ForegroundColor White
Write-Host "=============================================" -ForegroundColor Green
