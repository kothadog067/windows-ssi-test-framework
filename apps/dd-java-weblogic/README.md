# dd-java-weblogic

Tests SSI injection into **`wlsvc.exe`** (Oracle WebLogic Windows service wrapper). The ddinjector `java.c` explicitly detects `wlsvc.exe` and `wlsvcX64.exe` as Java injection targets via `is_weblogic_service()`.

## Implementation

Since Oracle WebLogic requires authentication to download, this test uses **Apache Commons Daemon (`prunsrv.exe`) renamed to `wlsvc.exe`** — an accurate simulation because:
- WebLogic's `wlsvc.exe` loads the JVM **in-process** (same as `prunsrv.exe`)
- The ddinjector detects by **process name only** — so `wlsvc.exe` triggers the injection path
- The Java tracer is injected into the live in-process JVM

## Services

| Service | Runtime | Port | DD_SERVICE |
|---------|---------|------|------------|
| WebLogic demo (wlsvc.exe) | Java 21 via wlsvc.exe | 8090 | java-weblogic-app |

## What This Tests

- **`is_weblogic_service()` detection**: `wlsvc.exe` and `wlsvcX64.exe` name matching in `java.c`
- **DLL injection**: `ddinjector_x64.dll` loaded into `wlsvc.exe`
- **Skip list**: Agent processes not instrumented
- **APM traces**: Spans appear in Datadog

## Quick Start

```powershell
.\scripts\setup.ps1 -DDApiKey "your_key" -InstallAgent
.\scripts\verify.ps1 -TargetHost localhost -DDApiKey "your_key"
.\scripts\teardown.ps1
```

## Endpoints

- `GET http://localhost:8090/health` → `{"status":"ok","service":"java-weblogic-app","process":"wlsvc.exe"}`
