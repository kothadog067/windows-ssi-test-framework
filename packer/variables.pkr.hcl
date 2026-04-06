# ──────────────────────────────────────────────────────────────────────────────
# variables.pkr.hcl — Input variables for the Windows SSI base AMI build
# ──────────────────────────────────────────────────────────────────────────────

variable "region" {
  description = "AWS region in which to build the AMI."
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "EC2 instance type used for the Packer build."
  type        = string
  default     = "t3.large"
}

variable "ami_name_prefix" {
  description = "Prefix for the output AMI name. A timestamp is appended automatically."
  type        = string
  default     = "windows-ssi-base"
}
