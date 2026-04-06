# dd-dotnet-selfcontained

Tests SSI injection into a **.NET 8 self-contained single-file executable** (`DotnetSelfContained.exe`). The ddinjector `dotnet.c` detects this app type via the PE `.data` bundle signature — a binary marker embedded in all `PublishSingleFile=true` outputs.

## Services

| Service | Runtime | Port | DD_SERVICE |
|---------|---------|------|------------|
| Self-contained HTTP server | .NET 8 self-contained (win-x64) | 8086 | dotnet-selfcontained-app |

## What This Tests

- **PE bundle detection**: `dotnet.c` reads the PE `.data` section and checks for the single-file bundle signature
- **DLL injection**: `ddinjector_x64.dll` loaded into `DotnetSelfContained.exe`
- **Skip list**: Agent processes not instrumented
- **APM traces**: Spans appear in Datadog with `_dd.tracer_version` tag

## Quick Start

```powershell
.\scripts\setup.ps1 -DDApiKey "your_key" -InstallAgent
.\scripts\verify.ps1 -TargetHost localhost -DDApiKey "your_key"
.\scripts\teardown.ps1
```

## Endpoints

- `GET http://localhost:8086/health` → `{"status":"ok","service":"dotnet-selfcontained-app","mode":"self-contained-single-file"}`
- `GET http://localhost:8086/info` → runtime and PID info
