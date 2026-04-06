output "instance_id" {
  value = module.ec2.instance_id
}

output "public_ip" {
  value = module.ec2.public_ip
}

output "service_url" {
  value = module.ec2.service_url
}

output "secondary_url" {
  value = module.ec2.secondary_url
}
