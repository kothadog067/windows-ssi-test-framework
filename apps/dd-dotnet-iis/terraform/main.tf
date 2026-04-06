terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ---------------------------------------------------------------------------
# Resolve latest Windows Server 2022 AMI when none is supplied
# ---------------------------------------------------------------------------
data "aws_ssm_parameter" "win2022_ami" {
  count = var.ami_id == "" ? 1 : 0
  name  = "/aws/service/ami-windows-latest/Windows_Server-2022-English-Full-Base"
}

locals {
  resolved_ami = var.ami_id != "" ? var.ami_id : data.aws_ssm_parameter.win2022_ami[0].value
}

# ---------------------------------------------------------------------------
# Security Group — HTTP (80), alternate HTTP (8082), RDP (3389)
# ---------------------------------------------------------------------------
resource "aws_security_group" "dd_dotnet_iis" {
  name        = "${var.app_name}-sg"
  description = "Security group for ${var.app_name}"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP port 80"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  ingress {
    description = "HTTP port 8082"
    from_port   = 8082
    to_port     = 8082
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  ingress {
    description = "RDP"
    from_port   = 3389
    to_port     = 3389
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.app_name}-sg"
  }
}

# ---------------------------------------------------------------------------
# EC2 Instance
# ---------------------------------------------------------------------------
resource "aws_instance" "dd_dotnet_iis" {
  ami                         = local.resolved_ami
  instance_type               = var.instance_type
  key_name                    = var.key_name
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.dd_dotnet_iis.id]
  associate_public_ip_address = true

  # Bootstrap: copy scripts then run setup.ps1 via user data
  user_data = <<-USERDATA
    <powershell>
    Set-ExecutionPolicy Bypass -Scope Process -Force

    # Give the instance a moment to settle
    Start-Sleep -Seconds 10

    # Re-invoke from a scheduled task so we have a full interactive-session-equivalent
    $cmd  = 'C:\setup\scripts\setup.ps1'
    $args = '-DDApiKey "${var.dd_api_key}" -DDSite "${var.dd_site}"'
    if ("${var.install_agent}" -eq "true") { $args += " -InstallAgent" }

    New-Item -ItemType Directory -Force -Path C:\setup\scripts | Out-Null
    # (Scripts are embedded via the shared module or uploaded separately)
    # For standalone use, paste the contents of scripts/*.ps1 here.
    </powershell>
    <persist>true</persist>
  USERDATA

  tags = {
    Name    = var.app_name
    App     = var.app_name
    DDEnv   = "demo"
  }
}
