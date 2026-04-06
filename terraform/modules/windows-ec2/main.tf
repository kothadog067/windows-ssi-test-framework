terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# ── AMI: latest Windows Server 2025 Base ─────────────────────────────────────
data "aws_ami" "windows_2025" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["Windows_Server-2025-English-Full-Base-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ── IAM: SSM access so we can run remote commands without WinRM ───────────────
resource "aws_iam_role" "ssm_role" {
  name = "ssi-test-ssm-${var.app_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm_profile" {
  name = "ssi-test-ssm-${var.app_name}"
  role = aws_iam_role.ssm_role.name
}

# ── Security Group ────────────────────────────────────────────────────────────
resource "aws_security_group" "app_sg" {
  name        = "ssi-test-${var.app_name}"
  description = "SSI test app: ${var.app_name}"

  ingress {
    description = "Game server"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }

  ingress {
    description = "Leaderboard / secondary service"
    from_port   = 8081
    to_port     = 8081
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }

  ingress {
    description = "RDP (debugging)"
    from_port   = 3389
    to_port     = 3389
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "ssi-test-${var.app_name}"
    SSITest = "true"
    App     = var.app_name
  }
}

# ── EC2 Instance ──────────────────────────────────────────────────────────────
resource "aws_instance" "app" {
  ami                    = data.aws_ami.windows_2025.id
  instance_type          = var.instance_type
  iam_instance_profile   = aws_iam_instance_profile.ssm_profile.name
  vpc_security_group_ids = [aws_security_group.app_sg.id]
  key_name               = var.key_name != "" ? var.key_name : null

  # Boot volume — Windows needs a bit more room
  root_block_device {
    volume_size = 50
    volume_type = "gp3"
  }

  # User data: bootstraps Chocolatey + git, clones repo, runs setup.ps1
  user_data = <<-USERDATA
    <powershell>
    $ErrorActionPreference = "Stop"
    $ProgressPreference    = "SilentlyContinue"

    function Log($m) { Write-Host "[USERDATA $(Get-Date -Format HH:mm:ss)] $m" }

    Log "=== SSI Test Bootstrap: ${var.app_name} ==="

    # 1. Install Chocolatey
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    $env:PATH += ";C:\ProgramData\chocolatey\bin"
    Log "Chocolatey ready"

    # 2. Install git
    choco install git -y --no-progress
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH","User")
    Log "Git ready"

    # 3. Clone the test repo
    git clone "${var.repo_url}" C:\ssi-test
    Log "Repo cloned"

    # 4. Run app-specific setup with Datadog agent install
    $setupScript = "C:\ssi-test\apps\${var.app_name}\scripts\setup.ps1"
    & $setupScript `
        -DDApiKey "${var.dd_api_key}" `
        -DDSite   "${var.dd_site}" `
        -InstallAgent

    Log "=== Bootstrap complete ==="
    </powershell>
    <persist>true</persist>
  USERDATA

  tags = {
    Name    = "ssi-test-${var.app_name}"
    SSITest = "true"
    App     = var.app_name
  }
}
