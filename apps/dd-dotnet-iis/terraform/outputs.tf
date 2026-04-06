output "instance_id" {
  description = "EC2 instance ID."
  value       = aws_instance.dd_dotnet_iis.id
}

output "public_ip" {
  description = "Public IP address of the instance."
  value       = aws_instance.dd_dotnet_iis.public_ip
}

output "public_dns" {
  description = "Public DNS name of the instance."
  value       = aws_instance.dd_dotnet_iis.public_dns
}

output "health_url_port80" {
  description = "Health check URL on port 80."
  value       = "http://${aws_instance.dd_dotnet_iis.public_ip}/health"
}

output "health_url_port8082" {
  description = "Health check URL on port 8082."
  value       = "http://${aws_instance.dd_dotnet_iis.public_ip}:8082/health"
}

output "security_group_id" {
  description = "ID of the security group."
  value       = aws_security_group.dd_dotnet_iis.id
}
