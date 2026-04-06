# dd-java-procrun

A Java HTTP server running as a native Windows Service managed by Apache Commons Daemon (Procrun). Tests Datadog SSI injection into a JVM process managed outside of NSSM.

## Endpoints

| Method | Path      | Port | Description                                         |
|--------|-----------|------|-----------------------------------------------------|
| GET    | `/health` | 8083 | Returns `{"status":"ok","service":"java-procrun-app"}` |
| GET    | `/ping`   | 8083 | Returns `{"pong":true}`                             |

## Quick Start

### Prerequisites

- Windows Server 2019/2022 with PowerShell 5.1+
- Java 11+ on the PATH (or let setup.ps1 install via Chocolatey)
- JDK (for `javac` / `jar`) — `microsoft-openjdk17` is installed automatically
- Administrator privileges

### Local setup

```powershell
cd apps\dd-java-procrun\scripts

# Minimal
.\setup.ps1

# With Datadog Agent and verification
.\setup.ps1 -DDApiKey "YOUR_KEY" -DDSite "datadoghq.com" -InstallAgent -Verify
```

### Verify independently

```powershell
.\verify.ps1 -TargetHost localhost -DDApiKey "YOUR_KEY" -WaitForTracesSec 60
```

### Teardown

```powershell
.\teardown.ps1
```

### Terraform (AWS)

```bash
cd apps/dd-java-procrun/terraform
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars
terraform init && terraform apply
```

## Architecture

```
prunsrv.exe (Windows Service: JavaProcrunSvc)
    |
    v (StartMode=Java, StartClass=ProcrunApp)
JVM  →  com.sun.net.httpserver.HttpServer  →  :8083
```

## Datadog SSI Notes

Environment variables are passed to the JVM via prunsrv.exe `--Environment`:

| Variable     | Value               |
|--------------|---------------------|
| `DD_SERVICE` | `java-procrun-app`  |
| `DD_ENV`     | `demo`              |
| `DD_VERSION` | `1.0.0`             |

The Datadog Java tracer agent, when installed alongside, will pick up these variables to tag all spans emitted by the service.
