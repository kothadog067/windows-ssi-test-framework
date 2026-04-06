$ErrorActionPreference = "Continue"
function Log($m) { Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $m" -ForegroundColor Cyan }
function OK($m)  { Write-Host "  [OK] $m" -ForegroundColor Green }

Log "=== dd-jvm-skiplist-kafka — Teardown ==="

$NssmPath = "C:\ProgramData\chocolatey\bin\nssm.exe"

foreach ($svc in @("KafkaBrokerSvc", "ZooKeeperSvc")) {
    if (Test-Path $NssmPath) {
        & $NssmPath stop   $svc 2>$null
        & $NssmPath remove $svc confirm 2>$null
    } else {
        Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
        sc.exe delete $svc 2>$null
    }
    OK "Service $svc removed"
}

Remove-Item -Recurse -Force "C:\kafka", "C:\kafka-logs", "C:\zookeeper-data" -ErrorAction SilentlyContinue
OK "Kafka installation removed"

OK "Teardown complete"
exit 0
