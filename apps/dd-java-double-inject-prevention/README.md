# dd-java-double-inject-prevention

Tests that the ddinjector **prevents double injection** when `JAVA_TOOL_OPTIONS` already contains a `-javaagent` flag pointing to `dd-java-agent.jar`. The `java.c` injection shim in ddinjector reads `JAVA_TOOL_OPTIONS` before appending its own `-javaagent` entry, and skips injection if `dd-java-agent` is already referenced.

**Pass condition: exactly 1 `-javaagent:dd-java-agent.jar` reference in `JAVA_TOOL_OPTIONS` after service start — never 2.**

## What It Tests

| Scenario | Setup | Expected Outcome |
|---|---|---|
| Manual pre-injection + SSI enabled | `JAVA_TOOL_OPTIONS=-javaagent:dd-java-agent.jar` set in service env; SSI also active | `dd_agent_count == 1` (ddinjector skips injection) |
| Registry double-injection check | Check service registry `Environment` key directly | Exactly 1 `dd-java-agent` reference in `JAVA_TOOL_OPTIONS` value |

If ddinjector does NOT perform the duplicate check, `JAVA_TOOL_OPTIONS` would contain two `-javaagent:dd-java-agent.jar` entries, causing the JVM to load the tracer twice — producing duplicate spans, corrupted trace context, and potentially a startup crash.

## Endpoints

| Method | Path | Port | Description |
|---|---|---|---|
| GET | `/health` | 8089 | Returns `{"status":"ok","service":"java-double-inject-test","java_tool_options":"...","dd_agent_count":N}` |

The `dd_agent_count` field counts how many `-javaagent` tokens referencing `dd-java-agent` are present in `JAVA_TOOL_OPTIONS` at runtime.

## Quick Start

### Prerequisites

- Windows Server 2019/2022 with PowerShell 5.1+
- Java 21 (Eclipse Temurin; installed automatically via Chocolatey if missing)
- NSSM (installed automatically via Chocolatey if missing)
- Administrator privileges

### Local setup

```powershell
cd apps\dd-java-double-inject-prevention\scripts

# Install agent, compile Java app, pre-set JAVA_TOOL_OPTIONS, start service
.\setup.ps1 -DDApiKey "YOUR_KEY" -DDSite "datadoghq.com" -InstallAgent

# Agent already installed — just build app and start service
.\setup.ps1

# Full end-to-end
.\setup.ps1 -DDApiKey "YOUR_KEY" -InstallAgent -Verify
```

### Verify independently

```powershell
.\verify.ps1 -TargetHost localhost
# exits 0 = double injection prevented (PASS)
# exits 1 = double injection detected or service not running (FAIL)
# prints JSON results and writes results.json
```

### Teardown

```powershell
.\teardown.ps1
# Removes service and C:\dd-double-inject; always exits 0
```

### Terraform (AWS)

```bash
cd apps/dd-java-double-inject-prevention/terraform
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars
terraform init -backend-config=backend.hcl.example
terraform apply
```

## Pass / Fail Conditions

| Check | Pass | Fail |
|---|---|---|
| `service_running` | `DDDoubleInjectTestSvc` status is Running | Service not running |
| `single_javaagent_only` | `dd_agent_count == 1` from `/health` | `dd_agent_count >= 2` (double injection) |
| `registry_jto_single` | Exactly 1 `dd-java-agent` reference in registry `JAVA_TOOL_OPTIONS` | 2+ references in registry (ddinjector appended despite pre-existing entry) |

## Architecture

```
setup.ps1
  -> downloads dd-java-agent.jar to C:\dd-double-inject\
  -> compiles DoubleInjectTestApp.java
  -> registers DDDoubleInjectTestSvc via NSSM with:
       JAVA_TOOL_OPTIONS=-javaagent:"C:\dd-double-inject\dd-java-agent.jar"
       DD_SERVICE=java-double-inject-test
  -> installs Datadog Agent (SSI enabled)
  -> starts service (ddinjector runs on java.exe, should detect pre-existing -javaagent)

verify.ps1
  -> checks service is running
  -> calls GET /health -> reads dd_agent_count (must == 1)
  -> reads HKLM:\...\DDDoubleInjectTestSvc\Environment -> counts dd-java-agent references
```

## Source Reference

The double-injection guard is implemented in the `java.c` file of the ddinjector source. It reads the process environment's `JAVA_TOOL_OPTIONS` value and searches for an existing `-javaagent` token containing `dd-java-agent`. If found, it logs a message and returns without appending a second entry.
