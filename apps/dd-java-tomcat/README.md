# dd-java-tomcat

Tests SSI injection into **Apache Tomcat 9** (`tomcat9.exe` process). This validates the recently shipped Tomcat support in the ddinjector — the `is_tomcat_exe()` function in `java.c` matches `tomcat` + digits + `.exe` (e.g., `tomcat9.exe`, `tomcat10.exe`).

## Services

| Service | Runtime | Port | DD_SERVICE |
|---------|---------|------|------------|
| Tomcat 9 demo webapp | Java 21 via tomcat9.exe | 8085 | java-tomcat-app |

## What This Tests

- **Process detection**: `tomcat9.exe` is matched by `is_tomcat_exe()` in `java.c`
- **DLL injection**: `ddinjector_x64.dll` loaded into `tomcat9.exe` (verified via `tasklist /m`)
- **Skip list**: Datadog agent processes (`datadogagent.exe`, etc.) are NOT instrumented
- **APM traces**: Spans with `_dd.tracer_version` tag appear in Datadog

## Quick Start

```powershell
.\scripts\setup.ps1 -DDApiKey "your_key" -InstallAgent
.\scripts\verify.ps1 -TargetHost localhost -DDApiKey "your_key"
.\scripts\teardown.ps1
```

## Endpoints

- `GET http://localhost:8085/dd-tomcat-demo/health.jsp` -> `{"status":"ok","service":"java-tomcat-app",...}`
