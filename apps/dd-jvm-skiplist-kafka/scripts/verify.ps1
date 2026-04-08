param(
    [string]$TargetHost       = "localhost",
    [string]$DDApiKey         = $env:DD_API_KEY,
    [string]$DDSite           = $(if ($env:DD_SITE) { $env:DD_SITE } else { "datadoghq.com" }),
    [int]   $TimeoutSec       = 30,
    [int]   $WaitForTracesSec = 60
)

Import-Module "$PSScriptRoot\..\..\scripts\verify_common.psm1" -Force

$ErrorActionPreference = "Continue"
$scriptStart = Get-Date
$failed      = 0
$results     = New-ResultsObject -TargetHost $TargetHost

# ── Service status ────────────────────────────────────────────────────────────
Write-Step "SERVICE STATUS"
$zkSvc     = Get-Service -Name "ZooKeeperSvc" -ErrorAction SilentlyContinue
$zkRunning = ($zkSvc -and $zkSvc.Status -eq "Running")
# Informational — no "pass" key; ZooKeeper down is a warning, not a hard failure
$results.checks["zookeeper_running"] = @{ service = "ZooKeeperSvc"; running = $zkRunning }
if ($zkRunning) { Write-OK "ZooKeeperSvc RUNNING" }
else            { Write-Warn "ZooKeeperSvc not running — Kafka may also be down" }

$kSvc         = Get-Service -Name "KafkaBrokerSvc" -ErrorAction SilentlyContinue
$kafkaRunning = ($kSvc -and $kSvc.Status -eq "Running")
$results.checks["kafka_running"] = @{ service = "KafkaBrokerSvc"; pass = $kafkaRunning }
if ($kafkaRunning) { Write-OK "KafkaBrokerSvc RUNNING" }
else               { Write-Fail "KafkaBrokerSvc NOT running — cannot test JVM skip list"; $failed++ }

# ── JVM skip list check — per-PID Kafka process detection ─────────────────────
Write-Step "JVM SKIP LIST CHECK (Kafka — workload_selection_hardcoded.json)"
Write-Host "  kafka.Kafka main class is in the JVM skip list." -ForegroundColor DarkGray
Write-Host "  Pass = ddinjector_x64.dll is NOT in java.exe running Kafka." -ForegroundColor DarkGray

$javaProcs    = Get-WmiObject Win32_Process -Filter "Name = 'java.exe'" -ErrorAction SilentlyContinue
$kafkaPIDs    = @()
$violations   = @()
$skippedClean = @()

foreach ($proc in $javaProcs) {
    try {
        $cmdLine = (Get-WmiObject Win32_Process -Filter "ProcessId = $($proc.ProcessId)").CommandLine
        if ($cmdLine -match "kafka\.Kafka|kafka\.zookeeper|org\.apache\.kafka") {
            $kafkaPIDs += $proc.ProcessId
            $output = & tasklist /fi "imagename eq java.exe" /fi "pid eq $($proc.ProcessId)" /m "ddinjector_x64.dll" 2>&1
            $hasDll = ($output | Where-Object { $_ -match "java.exe" }).Count -gt 0
            if ($hasDll) {
                $violations += "java.exe (PID $($proc.ProcessId))"
                Write-Fail "VIOLATION: ddinjector_x64.dll in java.exe (PID $($proc.ProcessId)) running Kafka"
                $failed++
            } else {
                $skippedClean += $proc.ProcessId
                Write-OK "java.exe (PID $($proc.ProcessId)) — Kafka process clean (DLL not loaded)"
            }
        }
    } catch { Write-Warn "Could not check java.exe PID $($proc.ProcessId): $_" }
}

if ($kafkaPIDs.Count -eq 0) {
    Write-Warn "No java.exe running Kafka found — is Kafka running?"
    $results.checks["kafka_jvm_skip_list"] = @{
        pass       = $false
        note       = "No Kafka java.exe process found — setup may have failed"
        kafka_pids = @()
    }
    $failed++
} else {
    $skipListPass = ($violations.Count -eq 0)
    $results.checks["kafka_jvm_skip_list"] = @{
        pass          = $skipListPass
        kafka_pids    = $kafkaPIDs
        violations    = $violations
        skipped_clean = $skippedClean
        note          = "workload_selection_hardcoded.json: kafka.Kafka in JVM skip list"
    }
    Write-Host "  Kafka JVM processes: $($kafkaPIDs.Count), clean: $($skippedClean.Count), violations: $($violations.Count)" -ForegroundColor DarkGray
}

# ── Broad tasklist check (informational — per-PID check above is authoritative)
Write-Step "TASKLIST BROAD CHECK (all java.exe instances)"
$output          = & tasklist /fi "imagename eq java.exe" /m "ddinjector_x64.dll" 2>&1
$anyJavaInjected = ($output | Where-Object { $_ -match "java.exe" }).Count -gt 0
if ($anyJavaInjected) { Write-Warn "Some java.exe has ddinjector_x64.dll — check per-PID results above" }
else                  { Write-OK "No java.exe processes have ddinjector_x64.dll" }
# Informational — no "pass" key
$results.checks["broad_java_dll_check"] = @{ any_java_injected = $anyJavaInjected; note = "per-PID check is authoritative" }

# ── Kafka port check (informational) ─────────────────────────────────────────
Write-Step "KAFKA PORT CHECK (port 9092)"
$kafkaPortOpen = $false
try {
    $tcp = New-Object System.Net.Sockets.TcpClient
    $tcp.Connect("localhost", 9092)
    $kafkaPortOpen = $tcp.Connected
    $tcp.Close()
} catch {}
if ($kafkaPortOpen) { Write-OK "Kafka broker listening on port 9092" }
else                { Write-Warn "Kafka port 9092 not responding (may still be starting)" }
# Informational — no "pass" key
$results.checks["kafka_port_9092"] = @{ port = 9092; open = $kafkaPortOpen }

$pass = Save-Results -Results $results -AppName "dd-jvm-skiplist-kafka" -ScriptStart $scriptStart
if ($pass) { exit 0 } else { exit 1 }
