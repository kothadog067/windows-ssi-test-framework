# dd-win-server-2019

OS coverage test: validates that Datadog SSI host-wide injection works correctly on **Windows Server 2019** (Build 17763 / LTSC). Runs a .NET 8 Worker Service registered with `sc.exe` — no NSSM, no IIS.

## What This Tests

| Question | How it's verified |
|----------|-------------------|
| Does SSI inject the tracer on Windows Server 2019? | `ddinjector_x64.dll` loaded in `WorkerSvc2019.exe` via `tasklist /m` |
| Do traces reach APM with `_dd.tracer_version`? | Datadog spans API query for `service:dd-win-2019-svc` |
| Are Datadog agent processes skip-listed correctly? | `datadogagent.exe`, `trace-agent.exe`, etc. must NOT have the injector DLL |

## Endpoints

| Method | Path      | Port | Description                                                          |
|--------|-----------|------|----------------------------------------------------------------------|
| GET    | `/health` | 8084 | Returns `{"status":"ok","service":"dd-win-2019-svc","pid":N}`       |

## Quick Start

### Prerequisites

- Windows Server 2019 with PowerShell 5.1+
- .NET 8 SDK on the PATH
- Administrator privileges

### Local setup

```powershell
cd apps\dd-win-server-2019\scripts

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
cd apps/dd-win-server-2019/terraform
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars
terraform init && terraform apply
```

The Terraform config resolves the latest Windows Server 2019 AMI automatically via AWS SSM:
```
/aws/service/ami-windows-latest/Windows_Server-2019-English-Full-Base
```

## Architecture

```
sc.exe  →  DDWorker2019Svc  →  WorkerSvc2019.exe (self-contained, win-x64)
                                       |
                       +--------------+---------------+
                       |                              |
               HttpListenerWorker             ComputeWorker
               (HTTP :8084)                   (periodic work loop)
```

## Datadog SSI Notes

Environment variables are injected via the Windows Service Control Manager registry key:

```
HKLM:\SYSTEM\CurrentControlSet\Services\DDWorker2019Svc\Environment  (REG_MULTI_SZ)
```

| Variable     | Value              |
|--------------|--------------------|
| `DD_SERVICE` | `dd-win-2019-svc`  |
| `DD_ENV`     | `demo`             |
| `DD_VERSION` | `1.0.0`            |
