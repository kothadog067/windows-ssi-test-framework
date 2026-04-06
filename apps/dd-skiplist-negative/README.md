# dd-skiplist-negative

A **negative test** that verifies ddinjector never instruments processes listed in `default-skiplist.yaml`. This includes all Datadog Agent sub-processes (`datadogagent.exe`, `trace-agent.exe`, `process-agent.exe`, `system-probe.exe`, `security-agent.exe`, `dogstatsd.exe`), critical Windows system processes (`lsass.exe`, `csrss.exe`, `svchost.exe`, etc.), and browsers (`chrome.exe`, `msedge.exe`, `firefox.exe`).

**Pass condition: `ddinjector_x64.dll` is NOT found in any running skip-listed process.**

## What It Tests

| Scenario | Expected Outcome |
|---|---|
| Datadog Agent sub-processes running with SSI enabled | `ddinjector_x64.dll` absent from all agent processes |
| Critical Windows system processes | `ddinjector_x64.dll` absent (would be catastrophic otherwise) |
| Browser processes | `ddinjector_x64.dll` absent (skip list prevents crashes) |
| `notepad.exe` canary | Not instrumented (informational) |

This test requires the Datadog Agent to be running so the agent processes themselves can be checked.

## Quick Start

### Prerequisites

- Windows Server 2019/2022 with PowerShell 5.1+
- Administrator privileges
- Datadog Agent installed and running (or use `-InstallAgent`)

### Local setup

```powershell
cd apps\dd-skiplist-negative\scripts

# Agent already installed
.\setup.ps1 -Verify

# Install agent then verify
.\setup.ps1 -DDApiKey "YOUR_KEY" -DDSite "datadoghq.com" -InstallAgent -Verify
```

### Verify independently

```powershell
.\verify.ps1 -TargetHost localhost
# exits 0 = no violations (PASS), exits 1 = skip list violated (FAIL)
# prints JSON results to stdout and writes results.json
```

### Teardown

```powershell
.\teardown.ps1
# Always exits 0; stops notepad canary process
```

### Terraform (AWS)

```bash
cd apps/dd-skiplist-negative/terraform
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars — set dd_api_key, key_name, etc.
terraform init -backend-config=backend.hcl.example
terraform apply
```

## Pass / Fail Conditions

| Check | Pass | Fail |
|---|---|---|
| `skiplist_no_violations` | 0 processes have `ddinjector_x64.dll` | Any skip-listed process has DLL loaded |
| `agent_running_datadogagent` | `datadogagent.exe` is running | Agent not running (warning only) |
| `agent_running_trace-agent` | `trace-agent.exe` is running | Agent not running (warning only) |
| `canary_notepad` | `notepad.exe` clean | Informational only |

Only skip list violations cause exit code 1. Agent-not-running warnings are reported but do not fail the test.

## Skip List Source

The skip list is derived from `src/policies/windows/default-skiplist.yaml` in the `dd-go/auto_inject` repository. Any changes to that file should be reflected in this test's `$skipList` hash table in `verify.ps1`.
