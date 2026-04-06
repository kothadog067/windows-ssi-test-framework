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

data "aws_ssm_parameter" "win2022_ami" {
  count = var.ami_id == "" ? 1 : 0
  name  = "/aws/service/ami-windows-latest/Windows_Server-2022-English-Full-Base"
}

locals {
  resolved_ami = var.ami_id != "" ? var.ami_id : data.aws_ssm_parameter.win2022_ami[0].value
}

resource "aws_security_group" "dd_java_procrun" {
  name        = "${var.app_name}-sg"
  description = "Security group for ${var.app_name}"
  vpc_id      = var.vpc_id

  ingress {
    description = "Java Procrun app port 8083"
    from_port   = 8083
    to_port     = 8083
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

resource "aws_instance" "dd_java_procrun" {
  ami                         = local.resolved_ami
  instance_type               = var.instance_type
  key_name                    = var.key_name
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.dd_java_procrun.id]
  associate_public_ip_address = true

  user_data = <<-USERDATA
    <powershell>
    Set-ExecutionPolicy Bypass -Scope Process -Force
    Start-Sleep -Seconds 10
    # Scripts are uploaded/embedded separately; this block is a placeholder.
    # See README for full bootstrap instructions.
    </powershell>
    <persist>true</persist>
  USERDATA

  tags = {
    Name  = var.app_name
    App   = var.app_name
    DDEnv = "demo"
  }
}
