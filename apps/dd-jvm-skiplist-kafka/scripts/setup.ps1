# =============================================================================
#  dd-jvm-skiplist-kafka — Setup Script
#  Negative test: Kafka is in workload_selection_hardcoded.json JVM skip list.
#  When java.exe runs Kafka, ddinjector detects kafka.Kafka (or similar) in the
#  JVM startup args and skips injection. Tests the JVM workload skip list.
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
Log "=== dd-jvm-skiplist-kafka — Setup ==="

$KafkaInstallDir = "C:\kafka"
$KafkaVersion    = "3.7.0"
$ScalaVersion    = "2.13"
$KafkaTgzUrl     = "https://downloads.apache.org/kafka/${KafkaVersion}/kafka_${ScalaVersion}-${KafkaVersion}.tgz"
$KafkaTgzPath    = "$env:TEMP\kafka.tgz"
$ZkServiceName   = "ZooKeeperSvc"
$KafkaServiceName= "KafkaBrokerSvc"
$NssmPath        = "C:\ProgramData\chocolatey\bin\nssm.exe"

# ── 1. Install Java 21 and NSSM ───────────────────────────────────────────────
Log "Step 1: Installing Java 21 and NSSM..."
Ensure-Chocolatey
if (-not (Get-Command java -ErrorAction SilentlyContinue)) {
    choco install temurin21 -y --no-progress
    $env:PATH += ";C:\Program Files\Eclipse Adoptium\jdk-21*\bin"
}
if (-not (Test-Path $NssmPath)) {
    choco install nssm -y --no-progress
}
OK "Java and NSSM ready"

# ── 2. Download and extract Kafka ──────────────────────────────────────────────
Log "Step 2: Downloading Apache Kafka $KafkaVersion..."
if (-not (Test-Path "$KafkaInstallDir\bin\windows\kafka-server-start.bat")) {
    # Download using curl (available on Windows Server 2019+)
    $ProgressPreference = "SilentlyContinue"
    Invoke-WebRequest -Uri $KafkaTgzUrl -OutFile $KafkaTgzPath

    # Extract tgz — use tar (available on Windows 10 1803+/Server 2019+)
    Log "Extracting Kafka..."
    New-Item -ItemType Directory -Force -Path "C:\" | Out-Null
    & tar -xzf $KafkaTgzPath -C "C:\"

    $extractedDir = Get-ChildItem "C:\" -Directory | Where-Object { $_.Name -like "kafka_*" } | Select-Object -First 1
    if ($extractedDir) {
        if (Test-Path $KafkaInstallDir) { Remove-Item -Recurse -Force $KafkaInstallDir }
        Rename-Item $extractedDir.FullName $KafkaInstallDir
    }
}
OK "Kafka installed at $KafkaInstallDir"

# ── 3. Configure Kafka ─────────────────────────────────────────────────────────
Log "Step 3: Configuring Kafka..."
$kafkaProps = "$KafkaInstallDir\config\server.properties"
# Use a non-default port to avoid conflicts
(Get-Content $kafkaProps) -replace "^listeners=.*", "listeners=PLAINTEXT://localhost:9092" |
    Set-Content $kafkaProps
(Get-Content $kafkaProps) -replace "^log.dirs=.*", "log.dirs=C:/kafka-logs" |
    Set-Content $kafkaProps
New-Item -ItemType Directory -Force -Path "C:\kafka-logs", "C:\zookeeper-data" | Out-Null

$zkProps = "$KafkaInstallDir\config\zookeeper.properties"
(Get-Content $zkProps) -replace "^dataDir=.*", "dataDir=C:/zookeeper-data" |
    Set-Content $zkProps

OK "Kafka and ZooKeeper configured"

# ── 4. Register ZooKeeper as Windows service ───────────────────────────────────
Log "Step 4: Registering ZooKeeper service..."
$javaExe = (Get-Command java).Source
$kafkaClasspath = "$KafkaInstallDir\libs\*"

# Build ZooKeeper startup command
$zkMainClass = "org.apache.zookeeper.server.quorum.QuorumPeerMain"

& $NssmPath stop   $ZkServiceName 2>$null
& $NssmPath remove $ZkServiceName confirm 2>$null
Start-Sleep -Seconds 2

& $NssmPath install $ZkServiceName $javaExe
& $NssmPath set     $ZkServiceName AppParameters "-cp `"$KafkaInstallDir\libs\*`" -Dlog4j.configuration=file:`"$KafkaInstallDir\config\log4j.properties`" kafka.zookeeper.ZooKeeperServerMain `"$KafkaInstallDir\config\zookeeper.properties`""
& $NssmPath set     $ZkServiceName AppDirectory  $KafkaInstallDir
& $NssmPath set     $ZkServiceName DisplayName   "ZooKeeper (Kafka dependency)"
& $NssmPath set     $ZkServiceName Start         SERVICE_AUTO_START
& $NssmPath set     $ZkServiceName AppEnvironmentExtra "JAVA_HOME=$((Get-Command java).Source | Split-Path | Split-Path)" "LOG_DIR=C:\kafka-logs"
OK "ZooKeeper service registered"

# ── 5. Register Kafka Broker as Windows service ────────────────────────────────
Log "Step 5: Registering Kafka Broker service..."
& $NssmPath stop   $KafkaServiceName 2>$null
& $NssmPath remove $KafkaServiceName confirm 2>$null
Start-Sleep -Seconds 2

# The key: Kafka main class is kafka.Kafka — this is what ddinjector matches in workload_selection_hardcoded.json
& $NssmPath install $KafkaServiceName $javaExe
& $NssmPath set     $KafkaServiceName AppParameters "-cp `"$KafkaInstallDir\libs\*`" -Dlog4j.configuration=file:`"$KafkaInstallDir\config\log4j.properties`" kafka.Kafka `"$KafkaInstallDir\config\server.properties`""
& $NssmPath set     $KafkaServiceName AppDirectory  $KafkaInstallDir
& $NssmPath set     $KafkaServiceName DisplayName   "Apache Kafka Broker"
& $NssmPath set     $KafkaServiceName Start         SERVICE_AUTO_START
& $NssmPath set     $KafkaServiceName AppEnvironmentExtra "JAVA_HOME=$((Get-Command java).Source | Split-Path | Split-Path)" "LOG_DIR=C:\kafka-logs" "KAFKA_HEAP_OPTS=-Xmx512m -Xms256m"
OK "Kafka Broker service registered (main class: kafka.Kafka)"

# ── 6. Install Datadog Agent + SSI ────────────────────────────────────────────
if ($InstallAgent) {
    if (-not $DDApiKey) { FAIL "-InstallAgent requires -DDApiKey or DD_API_KEY env var" }

    Log "Installing Datadog Agent (with SSI)..."
    $msiArgs = "/qn /i `"https://windows-agent.datadoghq.com/datadog-agent-7-latest.amd64.msi`"" +
               " /log C:\Windows\SystemTemp\install-datadog.log" +
               " APIKEY=`"$DDApiKey`" SITE=`"$DDSite`"" +
               " DD_APM_INSTRUMENTATION_ENABLED=`"host`"" +
               " DD_APM_INSTRUMENTATION_LIBRARIES=`"java:1`""
    $p = Start-Process -Wait -PassThru msiexec -ArgumentList $msiArgs
    if ($p.ExitCode -ne 0) { FAIL "msiexec failed ($($p.ExitCode)) — check C:\Windows\SystemTemp\install-datadog.log" }
    OK "Datadog Agent installed with SSI"
}

# ── 7. Start services ──────────────────────────────────────────────────────────
Log "Step 7: Starting ZooKeeper then Kafka..."
Start-Service -Name $ZkServiceName -ErrorAction SilentlyContinue
Start-Sleep -Seconds 10  # ZooKeeper needs time to start before Kafka

Start-Service -Name $KafkaServiceName -ErrorAction SilentlyContinue
Start-Sleep -Seconds 15  # Kafka startup takes ~10-15s

$zkSvc = Get-Service -Name $ZkServiceName -ErrorAction SilentlyContinue
$kSvc  = Get-Service -Name $KafkaServiceName -ErrorAction SilentlyContinue

if ($zkSvc -and $zkSvc.Status -eq "Running") { OK "ZooKeeper running" }
else { Log "WARNING: ZooKeeper may not have started — Kafka may fail" }

if ($kSvc -and $kSvc.Status -eq "Running") {
    OK "Kafka running — ddinjector should detect kafka.Kafka main class and SKIP injection"
} else {
    Log "WARNING: Kafka Broker may not have started yet. Check C:\kafka-logs for errors."
}

if ($Verify) {
    & "$ScriptDir\verify.ps1" -TargetHost "localhost"
}

Log "=== Setup complete ==="
