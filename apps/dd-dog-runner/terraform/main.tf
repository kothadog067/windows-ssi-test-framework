terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Optional S3 backend for shared state + locking.
  # To enable: copy backend.hcl.example → backend.hcl, fill in values, then:
  #   terraform init -backend-config=backend.hcl
  # Leave this block commented out to use local state (fine for one-off runs).
  #
  # backend "s3" {}
}

provider "aws" {
  region = var.region
}

module "ec2" {
  source = "../../../terraform/modules/windows-ec2"

  app_name      = "dd-dog-runner"
  dd_api_key    = var.dd_api_key
  dd_site       = var.dd_site
  instance_type = var.instance_type
  region        = var.region
  key_name      = var.key_name
  allowed_cidr  = var.allowed_cidr
}
