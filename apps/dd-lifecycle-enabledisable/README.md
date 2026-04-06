# dd-lifecycle-enabledisable

Tests the **full SSI enable/disable lifecycle** using `datadog-installer.exe apm instrument host` and `apm uninstrument host`. A .NET 8 minimal API service (`LifecycleTestSvc`) is used as the instrumentation target across three sequential phases.

**Pass condition: all three phases must succeed — DLL present when enabled, absent when disabled, present again when re-enabled.**

## What It Tests

| Phase | Action | Expected `ddinjector_x64.dll` in `dotnet.exe` |
|---|---|---|
| Phase 1 (ENABLED) | SSI enabled via `apm instrument host` before service start | Present |
| Phase 2 (DISABLED) | `apm uninstrument host` + service restart | Absent |
| Phase 3 (RE-ENABLED) | `apm instrument host` + service restart | Present |

This validates that the ddinjector can be cleanly toggled without requiring a full agent reinstall and that the registry-based injection mechanism is properly written and removed by the installer.

## Endpoints

| Method | Path | Port | Description |
|---|---|---|---|
| GET | `/health` | 8088 | Returns `{"status":"ok","service":"lifecycle-test-svc","version":"1.0"}` |

## Quick Start

### Prerequisites

- Windows Server 2019/2022 with PowerShell 5.1+
- .NET 8 SDK (installed automatically via Chocolatey if missing)
- NSSM (installed automatically via Chocolatey if missing)
- Administrator privileges

### Local setup

```powershell
cd apps\dd-lifecycle-enabledisable\scripts

# Install agent, build service, enable SSI, start service
.\setup.ps1 -DDApiKey "YOUR_KEY" -DDSite "datadoghq.com" -InstallAgent

# Agent already installed — just build service and enable SSI
.\setup.ps1

# Full end-to-end including verify
.\setup.ps1 -DDApiKey "YOUR_KEY" -InstallAgent -Verify
```

### Verify independently (runs all three phases)

```powershell
.\verify.ps1 -TargetHost localhost
# exits 0 = all phases pass, exits 1 = one or more phases failed
# prints JSON results and writes results.json
```

### Teardown

```powershell
.\teardown.ps1
# Re-enables SSI, removes service, removes C:\dd-lifecycle, removes firewall rule
# Always exits 0
```

### Terraform (AWS)

```bash
cd apps/dd-lifecycle-enabledisable/terraform
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars
terraform init -backend-config=backend.hcl.example
terraform apply
```

## Pass / Fail Conditions

| Check | Pass | Fail |
|---|---|---|
| `phase1_enabled_dll_present` | `ddinjector_x64.dll` in `dotnet.exe` | DLL absent (SSI not working) |
| `phase2_disabled_dll_absent` | `ddinjector_x64.dll` NOT in `dotnet.exe` | DLL still present (uninstrument failed) |
| `phase3_reenabled_dll_present` | `ddinjector_x64.dll` back in `dotnet.exe` | DLL absent (re-instrument failed) |
| `health_final` | HTTP 200 on port 8088 | Service crashed during lifecycle test |

## Architecture

```
setup.ps1
  -> builds LifecycleTestSvc (.NET 8 Minimal API, port 8088)
  -> registers as Windows service via NSSM
  -> runs: datadog-installer.exe apm instrument host
  -> starts service

verify.ps1
  -> Phase 1: check ddinjector_x64.dll in dotnet.exe (should be present)
  -> Phase 2: uninstrument + restart -> check DLL absent
  -> Phase 3: instrument + restart   -> check DLL present
  -> HTTP health check on port 8088
```

## Notes

- `verify.ps1` actively drives the lifecycle (calls instrument/uninstrument), so it is stateful and must only be run once per `setup.ps1` invocation.
- If `datadog-installer.exe` is not found, a fallback rename strategy is used for the DLL — results may vary.
- `teardown.ps1` always re-enables SSI before removing the service to leave the system in a known good state.
