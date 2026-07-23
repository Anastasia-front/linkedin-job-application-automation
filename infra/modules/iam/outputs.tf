output "instance_profile_name" {
  value = aws_iam_instance_profile.profile.name
}

output "ssm_parameter_arns" {
  value = local.ssm_parameter_arns
}
