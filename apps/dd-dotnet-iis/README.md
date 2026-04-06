# dd-dotnet-iis

ASP.NET Core 8 minimal API hosted on IIS, used to test Datadog SSI (Single-Step Instrumentation) injection via the IIS application pool.

## Endpoints

| Method | Path            | Port(s)   | Description                                      |
|--------|-----------------|-----------|--------------------------------------------------|
| GET    | `/health`       | 80, 8082  | Returns `{"status":"ok","service":"dotnet-iis-app"}` |
| GET    | `/echo?msg=...` | 80, 8082  | Echoes the `msg` query parameter                 |
| POST   | `/compute`      | 80, 8082  | Sums a JSON array of ints; returns `{"result":N}` |

## Quick Start

### Prerequisites

- Windows Server 2019/2022 with PowerShell 5.1+
- .NET 8 SDK (for publishing) — or use the Terraform path which handles everything
- Administrator privileges

### Local setup

```powershell
# From the repo root
cd apps\dd-dotnet-iis\scripts

# Minimal (no agent)
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
cd apps/dd-dotnet-iis/terraform
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars
terraform init
terraform apply
```

## Architecture

```
Internet
   |
   | :80 / :8082
   v
IIS (DDIisSite)
   |
   v
DDIisAppPool  <-- DD_ env vars set here for SSI pickup
   |
   v
ASP.NET Core (inprocess hosting)  →  IisApp.dll
```

## Datadog SSI Notes

The Datadog .NET tracer is injected via the IIS application pool. The following environment variables are set on the pool by `setup.ps1`:

| Variable     | Value          |
|--------------|----------------|
| `DD_SERVICE` | `dd-iis-app`   |
| `DD_ENV`     | `demo`         |
| `DD_VERSION` | `1.0.0`        |
