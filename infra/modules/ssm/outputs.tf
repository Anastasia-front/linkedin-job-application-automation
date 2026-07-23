output "env_parameter_path" {
  value = "${var.path_prefix}/env"
}

output "tls_certificate_parameter" {
  value = aws_ssm_parameter.nginx_origin_certificate.name
}

output "tls_private_key_parameter" {
  value = aws_ssm_parameter.nginx_origin_private_key.name
}
