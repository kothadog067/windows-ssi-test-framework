# dd-dotnet-native-svc

A .NET 8 Worker Service compiled as a self-contained Windows Service executable. Registered with `sc.exe` directly — no NSSM, no IIS. Tests Datadog SSI injection via registry-injected environment variables.

## Endpoints

| Method | Path      | Port | Description                                                    |
|--------|-----------|------|----------------------------------------------------------------|
| GET    | `/health` | 8084 | Returns `{"status":"ok","service":"dd-worker-svc","pid":N}`   |

## Background Workers

| Worker           | Description                                                  |
|------------------|--------------------------------------------------------------|
| `HttpListenerWorker` | Serves HTTP on port 8084 via `System.Net.HttpListener`   |
| `ComputeWorker`      | Periodic CPU-bound loop (sum 1..N every 15 seconds)      |

## Quick Start

### Prerequisites

- Windows Server 2019/2022 with PowerShell 5.1+
- .NET 8 SDK on the PATH
- Administrator privileges

### Local setup

```powershell
cd apps\dd-dotnet-native-svc\scripts

# Minimal
.\setup.ps1

# With Datadog Agent and verification
.\setup.ps1 -DDApiKey "YOUR_KEY" -DDSite "datadoghq.com" -InstallAgent -Verify
```

### Verify independently

```powershell
.\verify.ps1 -TargetHost localhost -DDApiKey "YOUR_KEY" -WaitForTracesSec 60
# exits 0 on success, 1 on failure; prints JSON result
```

### Teardown

```powershell
.\teardown.ps1
# Always exits 0
```

### Terraform (AWS)

```bash
cd apps/dd-dotnet-native-svc/terraform
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars
terraform init && terraform apply
```

## Architecture

```
sc.exe  →  DDWorkerSvc  →  WorkerSvc.exe (self-contained, win-x64)
                                 |
               +-----------------+------------------+
               |                                    |
        HttpListenerWorker                  ComputeWorker
        (HTTP :8084)                        (periodic work loop)
```

## Datadog SSI Notes

Environment variables are injected via the Windows Service Control Manager registry key:

```
HKLM:\SYSTEM\CurrentControlSet\Services\DDWorkerSvc\Environment  (REG_MULTI_SZ)
```

| Variable     | Value           |
|--------------|-----------------|
| `DD_SERVICE` | `dd-worker-svc` |
| `DD_ENV`     | `demo`          |
| `DD_VERSION` | `1.0.0`         |

The SCM injects these into the service process environment at start time, making them visible to the Datadog .NET tracer without modifying the system-wide environment.
