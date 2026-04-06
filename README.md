# Windows SSI Test Framework

Automated testing framework for **Datadog Windows Host-Wide SSI** (Single Step Instrumentation).

Each app in `apps/` is a self-contained test case with a **standardized external shape** — same Terraform entrypoint, same script names, same script interface — so automation can treat them all identically.

---

## Repo Structure

```
windows-ssi-test-framework/
├── run_all.sh                    # CI orchestrator — loops all apps
├── Makefile                      # convenience targets
├── terraform/
│   └── modules/
│       └── windows-ec2/          # shared Terraform module (reused by all apps)
│           ├── main.tf           # EC2 + IAM + security group + user data
│           ├── variables.tf
│           └── outputs.tf
└── apps/
    └── dd-dog-runner/            # .NET + Java demo app (more apps added here)
        ├── app/                  # service source code
        │   ├── dotnet-game-server/
        │   └── java-leaderboard/
        ├── scripts/
        │   ├── setup.ps1         # ← standard entrypoint (same name every app)
        │   ├── verify.ps1        # ← standard verify   (same name every app)
        │   └── teardown.ps1      # ← standard teardown (same name every app)
        └── terraform/
            ├── main.tf           # calls shared module
            ├── variables.tf
            ├── outputs.tf
            └── terraform.tfvars.example
```

---

## Standard Script Interface

Every app exposes the same three scripts with the same parameters:

| Script | Purpose | Key params |
|--------|---------|------------|
| `setup.ps1` | Install deps, build, register as Windows Services, optionally install DD Agent + SSI | `-DDApiKey`, `-DDSite`, `-InstallAgent`, `-Verify` |
| `verify.ps1` | Hit `/health` endpoints, check Windows service status, optionally query DD APM | `-TargetHost`, `-DDApiKey`, `-DDSite` |
| `teardown.ps1` | Stop/remove services, clean up files | (none) |

Exit codes: **0 = pass, 1 = fail** — consistent across all scripts.

---

## Standard Terraform Interface

Every app's `terraform/` exposes the same variables and outputs:

**Variables:** `dd_api_key`, `dd_site`, `instance_type`, `region`, `key_name`, `allowed_cidr`
**Outputs:** `instance_id`, `public_ip`, `service_url`, `secondary_url`

---

## Running Tests

### All apps (CI)

```bash
export DD_API_KEY=your_key
export AWS_REGION=us-east-1
bash run_all.sh
```

### Single app

```bash
APP_FILTER=dd-dog-runner bash run_all.sh
# or
make test-app APP=dd-dog-runner
```

### Manual (on the Windows EC2)

```powershell
.\setup.ps1 -DDApiKey "your_key" -DDSite "datadoghq.com" -InstallAgent
.\verify.ps1 -TargetHost localhost
.\teardown.ps1
```

### Provision only (leave running for debugging)

```bash
SKIP_DESTROY=1 APP_FILTER=dd-dog-runner bash run_all.sh
```

---

## Adding a New Test App

1. Create `apps/<your-app>/` with the standard shape:
   ```
   apps/your-app/
   ├── app/               # your service source code
   ├── scripts/
   │   ├── setup.ps1      # must accept: -DDApiKey, -DDSite, -InstallAgent, -Verify
   │   ├── verify.ps1     # must accept: -TargetHost, -DDApiKey, -DDSite; exit 0/1
   │   └── teardown.ps1
   └── terraform/
       ├── main.tf        # call the shared module: ../../../terraform/modules/windows-ec2
       ├── variables.tf
       ├── outputs.tf
       └── terraform.tfvars.example
   ```

2. `run_all.sh` will automatically pick it up on the next run.

---

## SSI Requirements

- Datadog Agent **v7.67.1+**
- Windows Server 2019 / 2022 / 2025
- .NET Tracer **v3.19.0+** (for .NET services)
- Java Tracer **v1.44.0+** (for Java services)
- Enrolled in Windows Host-Wide SSI preview

After the agent installs, services are restarted automatically to trigger injection. Check APM → Service Catalog for traces.
