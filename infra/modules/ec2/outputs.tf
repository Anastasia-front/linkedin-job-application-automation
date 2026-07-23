output "instance_id" {
  value = aws_instance.n8n.id
}

output "elastic_ip" {
  value = aws_eip.n8n.public_ip
}
