# dd-dotnet-x86

Tests SSI injection into a **32-bit (x86) .NET 8 self-contained process** (`DotnetX86App.exe`). The ddinjector ships two DLL variants: `ddinjector_x64.dll` for 64-bit processes and `ddinjector_x86.dll` for 32-bit processes. This test validates the **x86 injection code path**.

## Key Difference from Other .NET Tests

| Aspect | 64-bit apps | **This app (32-bit)** |
|--------|-------------|----------------------|
| DLL injected | `ddinjector_x64.dll` | **`ddinjector_x86.dll`** |
| Published with | `--runtime win-x64` | **`--runtime win-x86`** |
| Architecture | x64 | **x86 (32-bit)** |

## Services

| Service | Runtime | Port | DD_SERVICE |
|---------|---------|------|------------|
| 32-bit HTTP server | .NET 8 win-x86 self-contained | 8091 | dotnet-x86-app |

## What This Tests

- **32-bit process detection**: ddinjector identifies 32-bit processes and uses the x86 injection path
- **`ddinjector_x86.dll` loaded**: Authoritative DLL check using `tasklist /m ddinjector_x86.dll`
- **`ddinjector_x64.dll` absent**: 64-bit DLL should NOT be injected into a 32-bit process
- **APM traces**: Spans appear in Datadog from the 32-bit process

## Quick Start

```powershell
.\scripts\setup.ps1 -DDApiKey "your_key" -InstallAgent
.\scripts\verify.ps1 -TargetHost localhost -DDApiKey "your_key"
.\scripts\teardown.ps1
```

## Endpoints

- `GET http://localhost:8091/health` → `{"status":"ok","service":"dotnet-x86-app","is32bit":true}`
- `GET http://localhost:8091/info` → architecture and PID info
