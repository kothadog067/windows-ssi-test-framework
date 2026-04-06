output "instance_id" {
  description = "EC2 instance ID."
  value       = aws_instance.app.id
}

output "public_ip" {
  description = "Public IP address of the instance."
  value       = aws_instance.app.public_ip
}

output "service_url" {
  description = "Base URL for the primary service (port 8080)."
  value       = "http://${aws_instance.app.public_ip}:8080"
}

output "secondary_url" {
  description = "Base URL for the secondary service (port 8081)."
  value       = "http://${aws_instance.app.public_ip}:8081"
}

output "ami_id" {
  description = "AMI used for this instance."
  value       = data.aws_ami.windows_2025.id
}
