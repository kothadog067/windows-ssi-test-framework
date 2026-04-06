variable "dd_api_key"    { type = string; sensitive = true }
variable "dd_site"       { type = string; default = "datadoghq.com" }
variable "instance_type" { type = string; default = "t3.large" }
variable "region"        { type = string; default = "us-east-1" }
variable "key_name"      { type = string; default = "" }
variable "allowed_cidr"  { type = string; default = "0.0.0.0/0" }
