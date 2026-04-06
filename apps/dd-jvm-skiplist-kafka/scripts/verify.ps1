# =============================================================================
#  dd-jvm-skiplist-kafka — Verify Script
#  NEGATIVE TEST: Kafka is in workload_selection_hardcoded.json JVM skip list.
#  When java.exe runs kafka.Kafka main class, ddinjector detects it and skips.
#
#  Pass condition: java.exe running Kafka does NOT have ddinjector_x64.dll loaded.
#
#  Standard interface: verify.ps1 [-TargetHost <ip>] [-DDApiKey <key>]
#                                  [-DDSite <site>] [-WaitForTracesSec <n>]
#  Exit 0 = all checks pass (skip list enforced), Exit 1 = violation found.
# =============================================================================

param(
    [string]$TargetHost       = "localhost",
    [string]$DDApiKey         = $env:DD_API_KEY,
    [string]$DDSite           = $(if ($env:DD_SITE) { $env:DD_SITE } else { "datadoghq.com" }),
    [int]   $TimeoutSec       = 30,
    [int]   $WaitForTracesSec = 60
)

$ErrorActionPreference = "Continue"
$scriptStart           = Get-Date
$failed                = 0

function Write-Ok($m)   { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:failed++ }
function Write-Warn($m) { Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Write-Section($t) {
    Write-Host ""
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] ── $t" -ForegroundColor Cyan
}

$results = [ordered]@{
    timestamp    = (Get-Date -Format "o")
    target_host  = $TargetHost
    checks       = [ordered]@{}
    overall_pass = $false
}

# ── 1. Service status ─────────────────────────────────────────────────────────
Write-Section "SERVICE STATUS"

$zkSvc = Get-Service -Name "ZooKeeperSvc" -ErrorAction SilentlyContinue
$zkRunning = ($zkSvc -and $zkSvc.Status -eq "Running")
$results.checks["zookeeper_running"] = @{ service = "ZooKeeperSvc"; pass = $zkRunning }
if ($zkRunning) { Write-Ok "ZooKeeperSvc RUNNING" }
else            { Write-Warn "ZooKeeperSvc not running — Kafka may also be down" }

$kSvc = Get-Service -Name "KafkaBrokerSvc" -ErrorAction SilentlyContinue
$kafkaRunning = ($kSvc -and $kSvc.Status -eq "Running")
$results.checks["kafka_running"] = @{ service = "KafkaBrokerSvc"; pass = $kafkaRunning }
if ($kafkaRunning) { Write-Ok "KafkaBrokerSvc RUNNING" }
else               { Write-Fail "KafkaBrokerSvc NOT running — cannot test skip list" }

# ── 2. JVM SKIP LIST CHECK — Kafka must NOT have ddinjector_x64.dll ───────────
Write-Section "JVM SKIP LIST CHECK (Kafka — workload_selection_hardcoded.json)"
Write-Host "  Kafka's main class (kafka.Kafka) is in the JVM skip list." -ForegroundColor DarkGray
Write-Host "  Pass = ddinjector_x64.dll is NOT in java.exe running Kafka." -ForegroundColor DarkGray
Write-Host ""

# Find all java.exe processes and check their command lines
$javaProcs = Get-WmiObject Win32_Process -Filter "Name = 'java.exe'" -ErrorAction SilentlyContinue
if (-not $javaProcs) {
    $javaProcs = Get-Process -Name "java" -ErrorAction SilentlyContinue |
                 ForEach-Object { [PSCustomObject]@{ ProcessId = $_.Id; CommandLine = $_.StartInfo.Arguments } }
}

$kafkaPIDs    = @()
$violations   = @()
$skippedClean = @()

foreach ($proc in $javaProcs) {
    try {
        $cmdLine = (Get-WmiObject Win32_Process -Filter "ProcessId = $($proc.ProcessId)").CommandLine
        if ($cmdLine -match "kafka\.Kafka|kafka\.zookeeper|org\.apache\.kafka") {
            $kafkaPIDs += $proc.ProcessId
            $procName = "java.exe"

            # Check for DLL injection via tasklist
            $output = & tasklist /fi "imagename eq java.exe" /fi "pid eq $($proc.ProcessId)" /m "ddinjector_x64.dll" 2>&1
            $hasDll = ($output | Where-Object { $_ -match "java.exe" }).Count -gt 0

            if ($hasDll) {
                $violations += "java.exe (PID $($proc.ProcessId)) [cmd: $(($cmdLine -split '\s+' | Where-Object { $_ -match 'kafka' } | Select-Object -First 1))]"
                Write-Fail "VIOLATION: ddinjector_x64.dll found in java.exe (PID $($proc.ProcessId)) running Kafka"
            } else {
                $skippedClean += $proc.ProcessId
                Write-Ok "java.exe (PID $($proc.ProcessId)) — Kafka process clean (ddinjector_x64.dll NOT loaded)"
            }
        }
    } catch {
        Write-Warn "Could not check java.exe PID $($proc.ProcessId): $_"
    }
}

if ($kafkaPIDs.Count -eq 0) {
    Write-Warn "No java.exe processes running Kafka found — is Kafka running?"
    $results.checks["kafka_jvm_skip_list"] = @{
        pass        = $false
        note        = "No Kafka java.exe process found — setup may have failed"
        kafka_pids  = @()
    }
} else {
    $skipListPass = ($violations.Count -eq 0)
    $results.checks["kafka_jvm_skip_list"] = @{
        pass             = $skipListPass
        kafka_pids       = $kafkaPIDs
        violations       = $violations
        skipped_clean    = $skippedClean
        note             = "workload_selection_hardcoded.json: kafka.Kafka in JVM skip list"
    }
    Write-Host ""
    Write-Host "  Kafka JVM processes checked: $($kafkaPIDs.Count)" -ForegroundColor DarkGray
    Write-Host "  Clean (DLL absent): $($skippedClean.Count)" -ForegroundColor DarkGray
    Write-Host "  Violations: $($violations.Count)" -ForegroundColor DarkGray
}

# ── 3. Broader tasklist check (belt-and-suspenders) ───────────────────────────
Write-Section "TASKLIST BROAD CHECK (all java.exe instances)"
$output = & tasklist /fi "imagename eq java.exe" /m "ddinjector_x64.dll" 2>&1
$anyJavaInjected = ($output | Where-Object { $_ -match "java.exe" }).Count -gt 0

if ($anyJavaInjected) {
    # There ARE java.exe processes with the DLL — check if any are Kafka
    Write-Warn "ddinjector_x64.dll IS loaded in some java.exe process(es)"
    Write-Host "  (This may be a non-Kafka java.exe that IS correctly instrumented)" -ForegroundColor DarkGray
    $results.checks["kafka_processes_not_instrumented"] = @{
        pass = ($violations.Count -eq 0)
        note = "Some java.exe has DLL — but check is per-PID for Kafka processes"
    }
} else {
    Write-Ok "No java.exe processes have ddinjector_x64.dll loaded"
    $results.checks["kafka_processes_not_instrumented"] = @{ pass = $true }
}

# ── 4. Kafka port check (confirms Kafka is actually running) ───────────────────
Write-Section "KAFKA PORT CHECK (port 9092)"
$kafkaPortOpen = $false
try {
    $tcp = New-Object System.Net.Sockets.TcpClient
    $tcp.Connect("localhost", 9092)
    $kafkaPortOpen = $tcp.Connected
    $tcp.Close()
} catch {}

$results.checks["kafka_port_9092"] = @{ pass = $kafkaPortOpen; port = 9092 }
if ($kafkaPortOpen) { Write-Ok "Kafka broker listening on port 9092" }
else               { Write-Warn "Kafka port 9092 not responding (Kafka may still be starting)" }

# ── Summary ────────────────────────────────────────────────────────────────────
$elapsed = [math]::Round(((Get-Date) - $scriptStart).TotalSeconds)

# Only kafka_jvm_skip_list and kafka_running are hard failures
$criticalChecks = @("kafka_jvm_skip_list", "kafka_running")
$allPass = $true
foreach ($k in $criticalChecks) {
    if ($results.checks[$k] -and -not $results.checks[$k].pass) { $allPass = $false }
}
$results.overall_pass = $allPass

$json = $results | ConvertTo-Json -Depth 5
Write-Output $json
$json | Out-File -FilePath (Join-Path (Get-Location) "results.json") -Encoding utf8 -Force

Write-Host ""
if ($failed -eq 0) {
    Write-Host "  ALL CHECKS PASSED — Kafka JVM skip list enforced (${elapsed}s)" -ForegroundColor Green
    exit 0
} else {
    Write-Host "  $failed CHECK(S) FAILED (${elapsed}s)" -ForegroundColor Red
    exit 1
}
