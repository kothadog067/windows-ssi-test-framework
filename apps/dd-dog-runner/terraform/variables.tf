variable "dd_api_key" {
  description = "Datadog API key."
  type        = string
  sensitive   = true
}

variable "dd_site" {
  description = "Datadog site."
  type        = string
  default     = "datadoghq.com"
}

variable "instance_type" {
  description = "EC2 instance type."
  type        = string
  default     = "t3.xlarge"
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "key_name" {
  description = "EC2 key pair name (optional)."
  type        = string
  default     = ""
}

variable "allowed_cidr" {
  description = "CIDR allowed to reach app ports."
  type        = string
  default     = "0.0.0.0/0"
}
