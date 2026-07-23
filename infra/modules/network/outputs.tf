output "vpc_id" {
  value = local.vpc_id
}

output "subnet_id" {
  value = local.subnet_id
}

output "ec2_security_group_id" {
  value = aws_security_group.ec2.id
}
