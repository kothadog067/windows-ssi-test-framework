variable "region" {
  type    = string
  default = "us-east-1"
}

variable "state_bucket_name" {
  description = "Name of the S3 bucket for Terraform state. Must be globally unique."
  type        = string
  default     = "ssi-test-tf-state"
}

variable "lock_table_name" {
  description = "Name of the DynamoDB table for state locking."
  type        = string
  default     = "ssi-test-tf-locks"
}
