# dd-dotnet-framework

Tests SSI injection into a **.NET Framework 4.8** application (`DotnetFramework.exe`). The ddinjector `dotnet.c` detects Framework apps via the **PE COM descriptor** (`IMAGE_DIRECTORY_ENTRY_COM_DESCRIPTOR`) present in the PE header of all managed .NET Framework executables — a distinct code path from .NET Core/5+ apps.

## Services

| Service | Runtime | Port | DD_SERVICE |
|---------|---------|------|------------|
| HttpListener server | .NET Framework 4.8 | 8087 | dotnet-framework-app |

## What This Tests

- **PE COM descriptor detection**: `IMAGE_DIRECTORY_ENTRY_COM_DESCRIPTOR` present → Framework app path in `dotnet.c`
- **DLL injection**: `ddinjector_x64.dll` loaded into `DotnetFramework.exe`
- **Skip list**: Agent processes not instrumented
- **APM traces**: Spans appear in Datadog with `_dd.tracer_version` tag

## Quick Start

```powershell
.\scripts\setup.ps1 -DDApiKey "your_key" -InstallAgent
.\scripts\verify.ps1 -TargetHost localhost -DDApiKey "your_key"
.\scripts\teardown.ps1
```

## Endpoints

- `GET http://localhost:8087/health` → `{"status":"ok","service":"dotnet-framework-app","framework":"net48"}`
- `GET http://localhost:8087/info` → CLR version and PID
