locals {
  env_keys = nonsensitive(keys(var.env_values))
}

resource "aws_ssm_parameter" "env_vars" {
  for_each = toset(local.env_keys)

  name  = "${var.path_prefix}/env/${each.key}"
  type  = "SecureString"
  value = var.env_values[each.key]
}

resource "aws_ssm_parameter" "nginx_origin_certificate" {
  name             = "${var.path_prefix}/nginx/origin_certificate"
  type             = "SecureString"
  value_wo         = var.nginx_origin_certificate
  value_wo_version = var.nginx_origin_certificate_version
}

resource "aws_ssm_parameter" "nginx_origin_private_key" {
  name             = "${var.path_prefix}/nginx/origin_private_key"
  type             = "SecureString"
  value_wo         = var.nginx_origin_private_key
  value_wo_version = var.nginx_origin_private_key_version
}
