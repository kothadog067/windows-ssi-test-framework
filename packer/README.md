# Windows SSI Base AMI — Packer Build

This directory contains a [Packer HCL2](https://developer.hashicorp.com/packer/docs/templates/hcl_templates)
configuration that produces a pre-baked Windows Server 2025 AMI for the SSI
test framework. The AMI ships with all heavyweight dependencies already
installed, so individual test instances boot and become ready much faster than
a clean Windows image.

## What is baked in

| Component | Version / Notes |
|---|---|
| Chocolatey | Latest |
| Temurin JDK | 21 (via `temurin21` Chocolatey package) |
| .NET SDK | 8.0 (via `dotnet-8.0-sdk` Chocolatey package) |
| NSSM | Latest (Windows service wrapper) |
| Git | Latest |
| Datadog Agent MSI | Latest Agent 7 MSI staged to `C:\Datadog\` — **not configured** |

The Datadog Agent is intentionally left unconfigured (no API key, no site).
Configuration and service start happen at test time via user_data or SSM Run
Command so that secrets are never baked into the AMI.

## Prerequisites

- [Packer >= 1.9.0](https://developer.hashicorp.com/packer/downloads)
- AWS credentials available in the environment (env vars, `~/.aws/credentials`,
  or an IAM role) with permissions to:
  - `ec2:DescribeImages`, `ec2:RunInstances`, `ec2:CreateImage`,
    `ec2:CreateTags`, `ec2:TerminateInstances`
  - `iam:PassRole` if using an instance profile for the build instance

## Building the AMI

### 1. Initialize Packer plugins

```bash
cd /tmp/windows-ssi-test-framework/packer
packer init .
```

### 2. Validate the configuration

```bash
packer validate .
```

### 3. Build the AMI

```bash
# Default build (us-east-1, t3.large)
packer build .

# Override region or instance type
packer build \
  -var "region=us-west-2" \
  -var "instance_type=t3.xlarge" \
  .
```

The build takes approximately **20-30 minutes** due to Windows boot time,
WinRM setup, and Chocolatey package installation.

### 4. Retrieve the AMI ID

After a successful build, Packer writes `packer-manifest.json` in this
directory. Extract the AMI ID with:

```bash
jq -r '.builds[-1].artifact_id' packer-manifest.json | cut -d: -f2
```

Example output:

```
ami-0a1b2c3d4e5f67890
```

## Using the pre-baked AMI ID in Terraform

The `windows-ec2` Terraform module accepts an optional `ami_id` variable. When
set, it bypasses the data source lookup and uses the provided AMI directly.
When left empty (the default), Terraform falls back to looking up the latest
Windows Server 2025 Base AMI from Amazon — the original behavior.

### Option A — pass on the command line

```bash
cd /tmp/windows-ssi-test-framework/terraform
terraform apply \
  -var "ami_id=$(jq -r '.builds[-1].artifact_id' \
        /tmp/windows-ssi-test-framework/packer/packer-manifest.json | cut -d: -f2)" \
  -var "dd_api_key=<YOUR_KEY>"
```

### Option B — set in a `.tfvars` file

Create `terraform.tfvars` (or any `*.tfvars` file) inside your Terraform root
module:

```hcl
ami_id     = "ami-0a1b2c3d4e5f67890"
dd_api_key = "YOUR_DATADOG_API_KEY"
```

Then apply normally:

```bash
terraform apply
```

### Option C — use the data source output as a Terraform variable default

If you store the AMI ID in AWS SSM Parameter Store or another registry, you can
reference it in a `data "aws_ssm_parameter"` block and pass it through. The
`ami_id` variable in `variables.tf` accepts any non-empty string, so any
retrieval mechanism works.

## Rebuilding / rotating the AMI

Re-run `packer build .` at any time. Each build produces a uniquely named AMI
(`windows-ssi-base-YYYYMMDD-hhmmss`) and appends a new entry to
`packer-manifest.json`. Old AMIs are not deregistered automatically — manage
retention with your own lifecycle policy or the
[`amazon-ami-management` Packer post-processor](https://github.com/wata727/packer-plugin-amazon-ami-management).
