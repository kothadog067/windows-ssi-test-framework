output "state_bucket" {
  value = aws_s3_bucket.tf_state.bucket
}

output "lock_table" {
  value = aws_dynamodb_table.tf_locks.name
}

output "backend_hcl" {
  description = "Paste this into each app's backend.hcl file."
  value       = <<-EOT
    bucket         = "${aws_s3_bucket.tf_state.bucket}"
    key            = "ssi-tests/APP_NAME/terraform.tfstate"
    region         = "${var.region}"
    dynamodb_table = "${aws_dynamodb_table.tf_locks.name}"
    encrypt        = true
  EOT
}
