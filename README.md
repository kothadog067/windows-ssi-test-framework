# Windows SSI Test Framework

Automated, parallelized testing framework for **Datadog Windows Host-Wide SSI** (Single Step Instrumentation). Provisions real Windows EC2 instances, deploys services, validates APM trace injection end-to-end, and tears everything down — all from a single command.

---

## Architecture

```
windows-ssi-test-framework/
│
├── run_all.sh                        ← CI orchestrator (parallel, JUnit output, log collection)
├── Makefile                          ← convenience targets
├── scripts/
│   └── new_app.sh                    ← scaffold a new test app in one command
│
├── packer/                           ← pre-baked AMI with runtimes pre-installed
│   ├── windows-ssi-base.pkr.hcl
│   └── variables.pkr.hcl
│
├── terraform/
│   ├── bootstrap/                    ← one-time: creates S3 state bucket + DynamoDB lock table
│   └── modules/
│       ├── windows-ec2/              ← shared EC2 module (all apps use this)
│       └── cost-guard/               ← Lambda that kills stale SSITest instances every 15 min
│
└── apps/                             ← one directory per test app
    ├── dd-dog-runner/                ← .NET 8 (NSSM) + Java 21 (NSSM)
    ├── dd-dotnet-iis/                ← .NET 8 on IIS application pool (w3wp.exe)
    ├── dd-java-procrun/              ← Java via Apache Commons Daemon (prunsrv.exe)
    ├── dd-dotnet-native-svc/         ← .NET Worker Service via sc.exe (no NSSM)
    ├── dd-java-tomcat/               ← Java via Tomcat 9 (tomcat9.exe)
    ├── dd-dotnet-selfcontained/      ← .NET 8 self-contained single-file (PE bundle sig)
    ├── dd-dotnet-framework/          ← .NET Framework 4.8 (PE COM descriptor)
    ├── dd-skiplist-negative/         ← Negative: skip-listed processes NOT instrumented
    ├── dd-lifecycle-enabledisable/   ← Enable/disable SSI lifecycle (apm instrument/uninstrument)
    ├── dd-java-double-inject-prevention/ ← Java double injection prevention
    ├── dd-java-weblogic/               ← Java via wlsvc.exe (WebLogic service wrapper)
    ├── dd-dotnet-x86/                  ← 32-bit (x86) process injection (ddinjector_x86.dll)
    └── dd-jvm-skiplist-kafka/          ← JVM skip list: Kafka must NOT be instrumented
```

Every app under `apps/` has the **same external shape**:

```
apps/<app-name>/
├── app/                    service source code
├── scripts/
│   ├── setup.ps1           ← standard entrypoint (same interface across ALL apps)
│   ├── verify.ps1          ← standard verify     (same interface across ALL apps)
│   └── teardown.ps1        ← standard teardown   (same interface across ALL apps)
└── terraform/
    ├── main.tf             calls shared windows-ec2 module
    ├── variables.tf
    ├── outputs.tf
    ├── terraform.tfvars.example
    └── backend.hcl.example
```

---

## Standard Script Interface

| Script | Key params | Exit codes |
|--------|-----------|------------|
| `setup.ps1` | `-DDApiKey`, `-DDSite`, `-InstallAgent`, `-Verify` | 0 = success, 1 = failure |
| `verify.ps1` | `-TargetHost`, `-DDApiKey`, `-DDSite`, `-WaitForTracesSec` | 0 = all checks pass, 1 = failure |
| `teardown.ps1` | _(none)_ | 0 always |

`verify.ps1` does **real SSI validation**:
1. Generates live traffic (POST /score, GET /leaderboard, GET /health)
2. Checks Windows service status
3. Retries HTTP health checks (3x with 5s backoff)
4. Polls Datadog APM API v2 for spans with `_dd.tracer_version` tag (proves SSI injected the tracer)
5. Scans ddinjector logs and registry for injection confirmation
6. Writes a structured `results.json` with per-check pass/fail

---

## Standard Terraform Interface

**Variables** (same across all apps): `dd_api_key`, `dd_site`, `instance_type`, `region`, `key_name`, `allowed_cidr`, `ami_id`

**Outputs** (same across all apps): `instance_id`, `public_ip`, `service_url`, `secondary_url`

---

## Quick Start

### Prerequisites

- AWS CLI configured (`aws configure` or OIDC in CI)
- Terraform ≥ 1.5
- `jq`, `unzip` (on the machine running `run_all.sh`)
- Datadog API key with APM access

### Run all apps in parallel

```bash
export DD_API_KEY=your_key
export AWS_REGION=us-east-1
bash run_all.sh
```

All apps run simultaneously. Output goes to `results/<app>/run.log`. A live status table renders in terminals. When done:
- `results/junit-<timestamp>.xml` — JUnit XML for CI import
- `results/<app>/logs/` — app logs, DD agent log, Windows Event Log (collected before destroy)

### Run a single app

```bash
APP_FILTER=dd-dog-runner bash run_all.sh
# or
make test-app APP=dd-dog-runner
```

### Leave instances running (for debugging)

```bash
SKIP_DESTROY=1 APP_FILTER=dd-dog-runner bash run_all.sh
```

### Manual run on Windows EC2

```powershell
.\scripts\setup.ps1 -DDApiKey "your_key" -DDSite "datadoghq.com" -InstallAgent
.\scripts\verify.ps1 -TargetHost localhost -DDApiKey "your_key"
.\scripts\teardown.ps1
```

---

## CI/CD — GitHub Actions

Two workflows ship out of the box:

### `test.yml` — Test all apps

Triggers:
- **Nightly** at 2am UTC (full suite)
- **Push to `main`** when `apps/**` or `terraform/**` changes
- **Manual dispatch** — choose `APP_FILTER` and `SKIP_DESTROY`

Each app runs as a **matrix job in parallel**. On failure, logs and JUnit XML are uploaded as artifacts. A summary job posts a result table to the workflow summary.

Required secrets: `DD_API_KEY`, `DD_SITE`, `AWS_ROLE_ARN`, `AWS_REGION`, `TF_STATE_BUCKET`

### `packer-build.yml` — Build pre-baked AMI

Triggers on push to `packer/**`. Builds a Windows Server 2025 AMI with Java, .NET, NSSM, and git pre-installed — cuts per-test setup time from ~8 min to ~30 sec. AMI ID is printed to workflow summary.

---

## Pre-baked AMI (Packer)

Without a baked AMI, each test run downloads and installs Java, .NET 8, NSSM, and Chocolatey (~8 min of pure network I/O). The Packer build eliminates this.

```bash
cd packer
packer init .
packer build -var "region=us-east-1" .
# AMI ID written to packer-manifest.json
```

To use the baked AMI, pass its ID to Terraform:

```bash
# terraform.tfvars
ami_id = "ami-0abc123..."
```

Or via environment variable in CI:
```bash
TF_VAR_ami_id="ami-0abc123..." bash run_all.sh
```

See [`packer/README.md`](packer/README.md) for full details.

---

## Terraform State (S3 Backend)

By default, each app uses local state (fine for one-off runs). For team use or CI, enable the S3 backend:

**1. One-time bootstrap** (creates the bucket + DynamoDB lock table):

```bash
cd terraform/bootstrap
terraform init
terraform apply -var="state_bucket_name=your-unique-bucket-name"
# outputs the backend config to paste into each app
```

**2. Per-app setup**:

```bash
cd apps/dd-dog-runner/terraform
cp backend.hcl.example backend.hcl   # fill in your bucket name
terraform init -backend-config=backend.hcl
```

---

## Cost Guard

A Lambda function runs every 15 minutes and terminates any EC2 tagged `SSITest=true` that has been running longer than 2 hours (configurable). Deploy it once:

```bash
cd terraform/modules/cost-guard
terraform init
terraform apply -var="max_age_minutes=120"
```

To test without terminating anything:

```bash
terraform apply -var="max_age_minutes=120" -var="dry_run=true"
```

Emergency manual cleanup (terminates all running SSI test instances by tag):

```bash
make destroy-all AWS_REGION=us-east-1
```

---

## Test Apps

### Positive Tests (verify injection IS working)

| App | Runtime | Service type | Port(s) | Injection path | Process detected by |
|-----|---------|--------------|---------|----------------|---------------------|
| `dd-dog-runner` | .NET 8 + Java 21 | NSSM | 8080, 8081 | NSSM env vars | `dotnet.exe`, `java.exe` |
| `dd-dotnet-iis` | .NET 8 | IIS app pool | 80, 8082 | App pool env vars → AspNetCoreModuleV2 | `w3wp.exe` |
| `dd-java-procrun` | Java 21 | Apache Procrun (prunsrv) | 8083 | `--Environment` on prunsrv | `prunsrv.exe` (`is_procrun_service`) |
| `dd-dotnet-native-svc` | .NET 8 (self-contained) | sc.exe (native) | 8084 | Registry `HKLM\...\Services\...\Environment` | `WorkerSvc.exe` |
| `dd-java-tomcat` | Java 21 / Tomcat 9 | Tomcat Windows service | 8085 | Tomcat service env | `tomcat9.exe` (`is_tomcat_exe`) |
| `dd-dotnet-selfcontained` | .NET 8 single-file | sc.exe | 8086 | Registry env | `DotnetSelfContained.exe` (PE bundle sig) |
| `dd-dotnet-framework` | .NET Framework 4.8 | NSSM | 8087 | NSSM env vars | `DotnetFramework.exe` (PE COM descriptor) |
| `dd-java-weblogic` | Java 21 | wlsvc.exe (Procrun renamed) | 8090 | Service env | `wlsvc.exe` (`is_weblogic_service`) |
| `dd-dotnet-x86` | .NET 8 win-x86 | sc.exe (32-bit) | 8091 | Registry env | `DotnetX86App.exe` (PE bundle, x86 → `ddinjector_x86.dll`) |

### Negative / Edge-Case Tests

| App | What it tests | Pass condition |
|-----|---------------|----------------|
| `dd-skiplist-negative` | Skip list enforcement (`default-skiplist.yaml`) | `ddinjector_x64.dll` is NOT in `datadogagent.exe`, `trace-agent.exe`, `lsass.exe`, etc. |
| `dd-lifecycle-enabledisable` | Enable → Disable → Re-enable SSI cycle via `apm instrument host` / `apm uninstrument host` | DLL present after enable, absent after disable, present again after re-enable |
| `dd-java-double-inject-prevention` | Double injection prevention (`java.c` JAVA_TOOL_OPTIONS check) | Pre-existing `-javaagent` in `JAVA_TOOL_OPTIONS` → SSI does not add a second one |
| `dd-jvm-skiplist-kafka` | JVM workload skip list (`workload_selection_hardcoded.json`) | `ddinjector_x64.dll` is NOT loaded in `java.exe` running `kafka.Kafka` |

### Coverage Matrix

| Scenario | Covered? | App |
|----------|----------|-----|
| .NET via NSSM | ✅ | `dd-dog-runner` |
| Java via NSSM | ✅ | `dd-dog-runner` |
| .NET via IIS (w3wp.exe) | ✅ | `dd-dotnet-iis` |
| Java via Apache Procrun (prunsrv.exe) | ✅ | `dd-java-procrun` |
| .NET via sc.exe (native service) | ✅ | `dd-dotnet-native-svc` |
| Java via Tomcat 9 (tomcat9.exe) | ✅ | `dd-java-tomcat` |
| .NET 8 self-contained single-file (PE bundle sig) | ✅ | `dd-dotnet-selfcontained` |
| .NET Framework 4.8 (PE COM descriptor) | ✅ | `dd-dotnet-framework` |
| Skip list enforcement | ✅ | `dd-skiplist-negative` |
| Enable/disable lifecycle | ✅ | `dd-lifecycle-enabledisable` |
| Double injection prevention | ✅ | `dd-java-double-inject-prevention` |
| Java via WebLogic (wlsvc.exe) | ✅ | `dd-java-weblogic` |
| 32-bit (x86) process injection | ✅ | `dd-dotnet-x86` |
| JVM skip list (Kafka, Cassandra) | ✅ | `dd-jvm-skiplist-kafka` |

---

## Adding a New Test App

```bash
bash scripts/new_app.sh dd-dotnet-wcf
```

This generates the complete directory structure with pre-populated script templates (standard interface already wired up). Fill in the `TODO` sections and your app is automatically picked up by `run_all.sh` — no other changes needed.

---

## SSI Requirements

| Requirement | Version |
|------------|---------|
| Datadog Agent | v7.67.1+ |
| Windows Server | 2019 / 2022 / 2025 (all covered) |
| .NET Tracer (SSI) | v3.19.0+ |
| Java Tracer (SSI) | v1.44.0+ |
| Windows Host-Wide Preview | Must be enrolled |

After the agent installs, services are restarted automatically to trigger injection. `verify.ps1` confirms injection via APM span tags and ddinjector logs.

---

## Troubleshooting

**SSM timeout during test**
- Windows boot takes 3–5 min; the 10-min SSM wait covers this. If it still times out, check the EC2 IAM instance profile has `AmazonSSMManagedInstanceCore`.

**`Host: Not instrumented` in DD UI**
- Confirm Agent v7.67.1+. Restart services *after* the agent is installed. Check `C:\ProgramData\Datadog\logs\` for ddinjector errors.

**Traces not appearing**
- `verify.ps1` waits up to 60s (configurable with `-WaitForTracesSec`). Traces can take 30–90s after restart. APM timeout is a warning, not a hard failure.

**Service logs on a failed run**
- `results/<app>/logs/` — collected automatically before destroy. Contains service logs, DD agent log, and Windows Application Event Log.

**Manual log access (SKIP_DESTROY=1)**
```powershell
# On the Windows instance via RDP or SSM Session Manager:
Get-Content C:\dd-demo\dotnet-game-server\logs\game-server-error.log
Get-Content C:\ProgramData\Datadog\logs\agent.log
```
