variable "app_name" {
  description = "Name of the test app (e.g. dd-dog-runner). Used for tagging and SSM parameters."
  type        = string
}

variable "repo_url" {
  description = "GitHub repo HTTPS URL to clone on the instance."
  type        = string
  default     = "https://github.com/kothadog067/windows-ssi-test-framework.git"
}

variable "dd_api_key" {
  description = "Datadog API key for agent installation."
  type        = string
  sensitive   = true
}

variable "dd_site" {
  description = "Datadog site (e.g. datadoghq.com, datadoghq.eu)."
  type        = string
  default     = "datadoghq.com"
}

variable "instance_type" {
  description = "EC2 instance type."
  type        = string
  default     = "t3.large"
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "key_name" {
  description = "EC2 key pair name (optional, for RDP/debugging)."
  type        = string
  default     = ""
}

variable "allowed_cidr" {
  description = "CIDR block allowed to reach the app ports (8080/8081) and RDP."
  type        = string
  default     = "0.0.0.0/0"
}
