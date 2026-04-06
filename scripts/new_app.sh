#!/usr/bin/env bash
# =============================================================================
#  new_app.sh — scaffold a new SSI test app from the standard template
#
#  Usage:
#    bash scripts/new_app.sh <app-name>
#
#  Example:
#    bash scripts/new_app.sh dd-dotnet-wcf
#
#  Creates:
#    apps/<app-name>/
#    ├── README.md
#    ├── app/                        ← put your service source code here
#    ├── scripts/
#    │   ├── setup.ps1               ← standard interface, pre-populated
#    │   ├── verify.ps1              ← standard interface, pre-populated
#    │   └── teardown.ps1            ← standard interface, pre-populated
#    └── terraform/
#        ├── main.tf                 ← calls shared windows-ec2 module
#        ├── variables.tf
#        ├── outputs.tf
#        ├── terraform.tfvars.example
#        └── backend.hcl.example
# =============================================================================

set -euo pipefail

APP_NAME="${1:-}"
if [[ -z "$APP_NAME" ]]; then
    echo "Usage: bash scripts/new_app.sh <app-name>"
    echo "Example: bash scripts/new_app.sh dd-dotnet-wcf"
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$REPO_ROOT/apps/$APP_NAME"

if [[ -d "$APP_DIR" ]]; then
    echo "ERROR: $APP_DIR already exists. Choose a different name."
    exit 1
fi

echo "Scaffolding: $APP_DIR"

mkdir -p "$APP_DIR/app"
mkdir -p "$APP_DIR/scripts"
mkdir -p "$APP_DIR/terraform"

# ── README ───────────────────────────────────────────────────────────────────
cat > "$APP_DIR/README.md" <<README
# $APP_NAME

<!-- Describe what this app tests (runtime, service type, SSI injection path) -->

## Services

| Service | Runtime | Port | DD_SERVICE |
|---------|---------|------|------------|
| TODO    | TODO    | TODO | TODO       |

## Quick Start

\`\`\`powershell
.\\scripts\\setup.ps1 -DDApiKey "your_key" -InstallAgent
.\\scripts\\verify.ps1 -TargetHost localhost
.\\scripts\\teardown.ps1
\`\`\`

## Endpoints

- \`GET /health\` → \`{"status":"ok","service":"$APP_NAME"}\`
README

# ── setup.ps1 ─────────────────────────────────────────────────────────────────
cat > "$APP_DIR/scripts/setup.ps1" <<'SETUP'
# =============================================================================
#  __APP_NAME__ — Setup Script
#  Standard interface: setup.ps1 [-DDApiKey <key>] [-DDSite <site>]
#                                  [-InstallAgent] [-Verify]
#  Exit 0 = success, Exit 1 = failure. Run as Administrator.
# =============================================================================

param(
    [string]$DDApiKey    = $env:DD_API_KEY,
    [string]$DDSite      = $(if ($env:DD_SITE) { $env:DD_SITE } else { "datadoghq.com" }),
    [switch]$InstallAgent,
    [switch]$Verify
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"
$ScriptDir             = Split-Path -Parent $MyInvocation.MyCommand.Path
$AppDir                = Split-Path -Parent $ScriptDir

function Log($m)  { Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $m" -ForegroundColor Cyan }
function OK($m)   { Write-Host "  [OK] $m"   -ForegroundColor Green }
function FAIL($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; exit 1 }

Log "=== __APP_NAME__ — Setup ==="

# TODO: add your setup steps here
# Suggested sections:
#   1. Install prerequisites (choco install ...)
#   2. Build/publish app
#   3. Open firewall port
#   4. Register Windows Service (sc.exe / NSSM / IIS / Procrun)
#   5. Set DD_ env vars on the service
#   6. Start service and verify it's running

# ── Install Datadog Agent + SSI ───────────────────────────────────────────────
if ($InstallAgent) {
    if (-not $DDApiKey) { FAIL "-InstallAgent requires -DDApiKey or DD_API_KEY env var" }

    Log "Installing Datadog Agent..."
    $msiPath = "$env:TEMP\datadog-agent.msi"
    Invoke-WebRequest -Uri "https://s3.amazonaws.com/ddagent-windows-stable/datadog-agent-7-latest.amd64.msi" -OutFile $msiPath
    Start-Process msiexec.exe -Wait -ArgumentList @(
        "/i", $msiPath,
        "APIKEY=$DDApiKey", "SITE=$DDSite",
        "/qn", "/l*v", "$env:TEMP\dd-agent-install.log"
    )
    Restart-Service -Name "datadogagent" -ErrorAction SilentlyContinue
    OK "Datadog Agent installed"

    Log "Restarting app services to trigger SSI injection..."
    # TODO: Restart-Service <YourServiceName>
    Start-Sleep -Seconds 5
    OK "Services restarted — SSI injection triggered"
}

if ($Verify) {
    & "$ScriptDir\verify.ps1" -TargetHost "localhost"
}

Log "=== Setup complete ==="
SETUP

sed -i '' "s/__APP_NAME__/$APP_NAME/g" "$APP_DIR/scripts/setup.ps1"

# ── verify.ps1 ────────────────────────────────────────────────────────────────
cat > "$APP_DIR/scripts/verify.ps1" <<'VERIFY'
# =============================================================================
#  __APP_NAME__ — Verify Script
#  Standard interface: verify.ps1 [-TargetHost <ip>] [-DDApiKey <key>]
#                                  [-DDSite <site>] [-WaitForTracesSec <n>]
#  Exit 0 = all checks pass, Exit 1 = one or more checks failed.
# =============================================================================

param(
    [string]$TargetHost       = "localhost",
    [string]$DDApiKey         = $env:DD_API_KEY,
    [string]$DDSite           = $(if ($env:DD_SITE) { $env:DD_SITE } else { "datadoghq.com" }),
    [int]   $TimeoutSec       = 30,
    [int]   $WaitForTracesSec = 60
)

$ErrorActionPreference = "Continue"
$scriptStart           = Get-Date
$failed                = 0

function Write-Ok($m)   { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:failed++ }
function Write-Warn($m) { Write-Host "  [WARN] $m" -ForegroundColor Yellow }

# ── TODO: Windows service status check ───────────────────────────────────────
# $svc = Get-Service -Name "YourServiceName" -ErrorAction SilentlyContinue
# if ($svc -and $svc.Status -eq "Running") { Write-Ok "Service RUNNING" }
# else { Write-Fail "Service not running (status: $($svc.Status))" }

# ── TODO: HTTP health check ───────────────────────────────────────────────────
# try {
#     $resp = Invoke-WebRequest -Uri "http://${TargetHost}:PORT/health" -TimeoutSec $TimeoutSec -UseBasicParsing
#     $body = $resp.Content | ConvertFrom-Json
#     if ($body.status -eq "ok") { Write-Ok "/health ok" } else { Write-Fail "/health returned $($body.status)" }
# } catch { Write-Fail "/health failed: $_" }

# ── Structured JSON summary ───────────────────────────────────────────────────
$elapsed = [math]::Round(((Get-Date) - $scriptStart).TotalSeconds)
$summary = [ordered]@{ app = "__APP_NAME__"; failed = $failed; elapsed_sec = $elapsed }
$summary | ConvertTo-Json -Depth 3 | Out-File -FilePath (Join-Path (Get-Location) "results.json") -Encoding utf8 -Force

if ($failed -eq 0) { Write-Host "  ALL CHECKS PASSED" -ForegroundColor Green; exit 0 }
else               { Write-Host "  $failed CHECK(S) FAILED" -ForegroundColor Red;  exit 1 }
VERIFY

sed -i '' "s/__APP_NAME__/$APP_NAME/g" "$APP_DIR/scripts/verify.ps1"

# ── teardown.ps1 ──────────────────────────────────────────────────────────────
cat > "$APP_DIR/scripts/teardown.ps1" <<'TEARDOWN'
# =============================================================================
#  __APP_NAME__ — Teardown Script
#  Stops and removes all services and cleans up app files.
#  Exit 0 always. Run as Administrator.
# =============================================================================

$ErrorActionPreference = "Continue"

function Log($m) { Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $m" -ForegroundColor Cyan }
function OK($m)  { Write-Host "  [OK] $m" -ForegroundColor Green }

Log "=== __APP_NAME__ — Teardown ==="

# TODO: stop and remove your services
# Stop-Service -Name "YourService" -Force -ErrorAction SilentlyContinue
# sc.exe delete "YourService"

# TODO: remove app directory
# Remove-Item -Recurse -Force "C:\your-app-dir" -ErrorAction SilentlyContinue

# TODO: remove firewall rules
# netsh advfirewall firewall delete rule name="Your Rule" | Out-Null

OK "Teardown complete"
exit 0
TEARDOWN

sed -i '' "s/__APP_NAME__/$APP_NAME/g" "$APP_DIR/scripts/teardown.ps1"

# ── terraform/main.tf ─────────────────────────────────────────────────────────
cat > "$APP_DIR/terraform/main.tf" <<TFMAIN
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Optional S3 backend:
  #   cp backend.hcl.example backend.hcl   # fill in your bucket name
  #   terraform init -backend-config=backend.hcl
  # backend "s3" {}
}

provider "aws" {
  region = var.region
}

module "ec2" {
  source = "../../../terraform/modules/windows-ec2"

  app_name      = "$APP_NAME"
  dd_api_key    = var.dd_api_key
  dd_site       = var.dd_site
  instance_type = var.instance_type
  region        = var.region
  key_name      = var.key_name
  allowed_cidr  = var.allowed_cidr
}
TFMAIN

# ── terraform/variables.tf ────────────────────────────────────────────────────
cat > "$APP_DIR/terraform/variables.tf" <<'TFVARS'
variable "dd_api_key"    { type = string; sensitive = true }
variable "dd_site"       { type = string; default = "datadoghq.com" }
variable "instance_type" { type = string; default = "t3.large" }
variable "region"        { type = string; default = "us-east-1" }
variable "key_name"      { type = string; default = "" }
variable "allowed_cidr"  { type = string; default = "0.0.0.0/0" }
TFVARS

# ── terraform/outputs.tf ──────────────────────────────────────────────────────
cat > "$APP_DIR/terraform/outputs.tf" <<'TFOUTS'
output "instance_id"   { value = module.ec2.instance_id }
output "public_ip"     { value = module.ec2.public_ip }
output "service_url"   { value = module.ec2.service_url }
output "secondary_url" { value = module.ec2.secondary_url }
TFOUTS

# ── terraform/terraform.tfvars.example ───────────────────────────────────────
cat > "$APP_DIR/terraform/terraform.tfvars.example" <<TFEX
# Copy to terraform.tfvars and fill in. NEVER commit terraform.tfvars.
dd_api_key    = "YOUR_DD_API_KEY"
dd_site       = "datadoghq.com"
instance_type = "t3.large"
region        = "us-east-1"
key_name      = ""
allowed_cidr  = "0.0.0.0/0"
TFEX

# ── terraform/backend.hcl.example ────────────────────────────────────────────
cat > "$APP_DIR/terraform/backend.hcl.example" <<BACKEND
# Copy to backend.hcl and fill in. Run: terraform init -backend-config=backend.hcl
# Create bucket first: cd terraform/bootstrap && terraform apply
bucket         = "ssi-test-tf-state"
key            = "ssi-tests/$APP_NAME/terraform.tfstate"
region         = "us-east-1"
dynamodb_table = "ssi-test-tf-locks"
encrypt        = true
BACKEND

chmod +x "$APP_DIR/scripts/setup.ps1"
chmod +x "$APP_DIR/scripts/verify.ps1"
chmod +x "$APP_DIR/scripts/teardown.ps1"

echo ""
echo "Created: $APP_DIR"
echo ""
echo "Next steps:"
echo "  1. Add your service code to apps/$APP_NAME/app/"
echo "  2. Fill in the TODO sections in scripts/setup.ps1 and scripts/verify.ps1"
echo "  3. Update apps/$APP_NAME/README.md"
echo "  4. Test locally: cd apps/$APP_NAME && .\\scripts\\setup.ps1 -DDApiKey \$env:DD_API_KEY"
echo "  5. Add to CI: the app is auto-discovered by run_all.sh"
