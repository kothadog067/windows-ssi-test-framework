# =============================================================================
#  dd-java-double-inject-prevention — Setup Script
#  Tests that ddinjector prevents loading dd-java-agent.jar twice when
#  JAVA_TOOL_OPTIONS already contains -javaagent pointing to dd-java-agent.jar.
#  Source: java.c checks JAVA_TOOL_OPTIONS before injecting; skips if already set.
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
$AppDir                = Split-Path -Parent $ScriptDir

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
Log "=== dd-java-double-inject-prevention — Setup ==="

$ServiceName  = "DDDoubleInjectTestSvc"
$InstallRoot  = "C:\dd-double-inject"
$NssmPath     = "C:\ProgramData\chocolatey\bin\nssm.exe"
$AppPort      = 8089

# ── 1. Install Java 21 ────────────────────────────────────────────────────────
Log "Step 1: Installing Java 21..."
Ensure-Chocolatey
if (-not (Get-Command java -ErrorAction SilentlyContinue)) {
    choco install temurin21 -y --no-progress
    $env:PATH += ";C:\Program Files\Eclipse Adoptium\jdk-21*\bin"
}
$javaHome = (Get-Command java).Source | Split-Path | Split-Path
OK "Java home: $javaHome"

# ── 2. Install NSSM ───────────────────────────────────────────────────────────
if (-not (Test-Path $NssmPath)) {
    choco install nssm -y --no-progress
}
OK "NSSM available"

# ── 3. Create a simple Java HTTP server ───────────────────────────────────────
Log "Step 3: Creating Java HTTP server..."
New-Item -ItemType Directory -Force -Path "$InstallRoot\app" | Out-Null

@'
import com.sun.net.httpserver.HttpServer;
import com.sun.net.httpserver.HttpHandler;
import com.sun.net.httpserver.HttpExchange;
import java.io.*;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;

public class DoubleInjectTestApp {
    public static void main(String[] args) throws Exception {
        int port = 8089;
        HttpServer server = HttpServer.create(new InetSocketAddress(port), 0);

        server.createContext("/health", exchange -> {
            String jto   = System.getenv("JAVA_TOOL_OPTIONS");
            if (jto == null) jto = System.getProperty("java.tool.options", "");
            long agentCount = java.util.Arrays.stream(jto.split("\\s+"))
                .filter(s -> s.contains("-javaagent") && s.contains("dd-java-agent"))
                .count();
            String response = String.format(
                "{\"status\":\"ok\",\"service\":\"java-double-inject-test\",\"java_tool_options\":\"%s\",\"dd_agent_count\":%d}",
                jto.replace("\"", "\\\""), agentCount);
            byte[] body = response.getBytes(StandardCharsets.UTF_8);
            exchange.getResponseHeaders().set("Content-Type", "application/json");
            exchange.sendResponseHeaders(200, body.length);
            try (OutputStream os = exchange.getResponseBody()) { os.write(body); }
        });

        server.start();
        System.out.println("[DoubleInjectTest] Listening on port " + port);
        Runtime.getRuntime().addShutdownHook(new Thread(server::stop));
        Thread.currentThread().join();
    }
}
'@ | Out-File -FilePath "$InstallRoot\app\DoubleInjectTestApp.java" -Encoding utf8 -Force

Push-Location "$InstallRoot\app"
& javac DoubleInjectTestApp.java
Pop-Location
OK "Java app compiled"

# ── 4. Download dd-java-agent.jar (manual injection) ─────────────────────────
Log "Step 4: Downloading dd-java-agent.jar for manual pre-injection..."
$JarPath = "$InstallRoot\dd-java-agent.jar"
$JarUrl  = "https://dtdg.co/latest-java-tracer"
Invoke-WebRequest -Uri $JarUrl -OutFile $JarPath
OK "dd-java-agent.jar downloaded to $JarPath"

# ── 5. Open firewall ───────────────────────────────────────────────────────────
netsh advfirewall firewall add rule name="DoubleInjectTest" dir=in action=allow protocol=TCP localport=$AppPort | Out-Null

# ── 6. Register Windows Service via NSSM with PRE-SET JAVA_TOOL_OPTIONS ───────
Log "Step 6: Registering service with JAVA_TOOL_OPTIONS pre-set (manual injection)..."
& $NssmPath stop   $ServiceName 2>$null
& $NssmPath remove $ServiceName confirm 2>$null
Start-Sleep -Seconds 2

# Register NSSM service running java.exe with the app
& $NssmPath install $ServiceName (Get-Command java).Source
& $NssmPath set     $ServiceName AppParameters "-cp `"$InstallRoot\app`" DoubleInjectTestApp"
& $NssmPath set     $ServiceName AppDirectory  "$InstallRoot\app"
& $NssmPath set     $ServiceName DisplayName   "Datadog Java Double Inject Prevention Test"
& $NssmPath set     $ServiceName Start         SERVICE_AUTO_START

# THE KEY: Pre-set JAVA_TOOL_OPTIONS with -javaagent (simulating manual instrumentation)
# The ddinjector java.c should detect this and NOT inject again
& $NssmPath set $ServiceName AppEnvironmentExtra `
    "JAVA_TOOL_OPTIONS=-javaagent:`"$JarPath`"" `
    "DD_SERVICE=java-double-inject-test" `
    "DD_ENV=demo" `
    "DD_VERSION=1.0"

OK "Service registered with JAVA_TOOL_OPTIONS=-javaagent:$JarPath (pre-injected)"

# ── 7. Install Datadog Agent + SSI ────────────────────────────────────────────
if ($InstallAgent) {
    if (-not $DDApiKey) { FAIL "-InstallAgent requires -DDApiKey or DD_API_KEY env var" }

    Log "Installing Datadog Agent..."
    $msiPath = "$env:TEMP\datadog-agent.msi"
    Invoke-WebRequest -Uri "https://s3.amazonaws.com/ddagent-windows-stable/datadog-agent-7-latest.amd64.msi" -OutFile $msiPath
    Start-Process msiexec.exe -Wait -ArgumentList @(
        "/i", $msiPath,
        "APIKEY=$DDApiKey", "SITE=$DDSite",
        "/qn", "/l*v", "$env:TEMP\dd-agent-install.log"
    )
    Restart-Service -Name "datadogagent" -ErrorAction SilentlyContinue
    OK "Datadog Agent installed — SSI will attempt injection but should detect existing -javaagent"
}

# ── 8. Start service ───────────────────────────────────────────────────────────
Log "Step 8: Starting service..."
Start-Service -Name $ServiceName
Start-Sleep -Seconds 5

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq "Running") {
    OK "Service running — verify.ps1 will check for double injection prevention"
} else {
    FAIL "Service failed to start"
}

if ($Verify) {
    & "$ScriptDir\verify.ps1" -TargetHost "localhost" -DDApiKey $DDApiKey -DDSite $DDSite
}

Log "=== Setup complete ==="
