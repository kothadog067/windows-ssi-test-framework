output "instance_id" {
  description = "EC2 instance ID."
  value       = aws_instance.dd_dotnet_native_svc.id
}

output "public_ip" {
  description = "Public IP address."
  value       = aws_instance.dd_dotnet_native_svc.public_ip
}

output "public_dns" {
  description = "Public DNS name."
  value       = aws_instance.dd_dotnet_native_svc.public_dns
}

output "health_url" {
  description = "Health check URL."
  value       = "http://${aws_instance.dd_dotnet_native_svc.public_ip}:8084/health"
}

output "security_group_id" {
  description = "Security group ID."
  value       = aws_security_group.dd_dotnet_native_svc.id
}
