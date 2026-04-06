terraform {
  required_providers {
    aws = { source = "hashicorp/aws"; version = "~> 5.0" }
  }
  # backend "s3" {}
}
provider "aws" { region = var.region }
module "ec2" {
  source        = "../../../terraform/modules/windows-ec2"
  app_name      = "dd-dotnet-framework"
  dd_api_key    = var.dd_api_key
  dd_site       = var.dd_site
  instance_type = var.instance_type
  region        = var.region
  key_name      = var.key_name
  allowed_cidr  = var.allowed_cidr
}
