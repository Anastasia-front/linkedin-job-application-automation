variable "project_name" {
  type = string
}

variable "path_prefix" {
  description = "SSM parameter path prefix under which env vars and TLS material are stored. Must match the path_prefix given to the iam module for the same environment."
  type        = string
}

variable "env_values" {
  type      = map(string)
  sensitive = true
}

variable "nginx_origin_certificate" {
  type      = string
  sensitive = true
}

variable "nginx_origin_certificate_version" {
  type = number
}

variable "nginx_origin_private_key" {
  type      = string
  sensitive = true
}

variable "nginx_origin_private_key_version" {
  type = number
}
