variable "app_name" {
  description = "Name tag applied to all resources."
  type        = string
  default     = "dd-java-weblogic"
}

variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "EC2 instance type (must support Windows)."
  type        = string
  default     = "t3.medium"
}

variable "ami_id" {
  description = "Windows Server 2022 AMI ID. Leave empty to use the latest from SSM."
  type        = string
  default     = ""
}

variable "key_name" {
  description = "EC2 key pair name for RDP access."
  type        = string
}

variable "dd_api_key" {
  description = "Datadog API key (passed to setup.ps1)."
  type        = string
  sensitive   = true
  default     = ""
}

variable "dd_site" {
  description = "Datadog site (e.g. datadoghq.com)."
  type        = string
  default     = "datadoghq.com"
}

variable "install_agent" {
  description = "Whether to install the Datadog Agent via setup.ps1."
  type        = bool
  default     = false
}

variable "vpc_id" {
  description = "VPC ID to launch the instance in."
  type        = string
}

variable "subnet_id" {
  description = "Subnet ID to launch the instance in."
  type        = string
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed inbound to the app port and RDP."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
