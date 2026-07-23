output "instance_id" {
  value = module.ec2.instance_id
}

output "elastic_ip" {
  value       = module.ec2.elastic_ip
  description = "Cloudflare DNS: Type A, Name n8n, Value this Elastic IP, Proxy status Proxied."
}

output "security_group_id" {
  value = module.network.ec2_security_group_id
}

output "public_hostname" {
  value = var.public_hostname
}

output "cloudflare_dns_instruction" {
  value = "Create Cloudflare DNS A record: n8n -> ${module.ec2.elastic_ip}, Proxy status: Proxied."
}

# ---------------------------------------------------------------------------
# Demo environment outputs (null when n8n_demo_enabled = false)
# ---------------------------------------------------------------------------

output "demo_instance_id" {
  value = var.n8n_demo_enabled ? module.ec2_demo[0].instance_id : null
}

output "demo_elastic_ip" {
  value       = var.n8n_demo_enabled ? module.ec2_demo[0].elastic_ip : null
  description = "Cloudflare DNS: Type A, Name demo-n8n, Value this Elastic IP, Proxy status Proxied."
}

output "demo_security_group_id" {
  value = var.n8n_demo_enabled ? module.network_demo[0].ec2_security_group_id : null
}

output "demo_public_hostname" {
  value = var.n8n_demo_domain
}

output "demo_cloudflare_dns_instruction" {
  value = var.n8n_demo_enabled ? "Create Cloudflare DNS A record: demo-n8n -> ${module.ec2_demo[0].elastic_ip}, Proxy status: Proxied. Do NOT put this hostname behind Cloudflare Access." : null
}

output "demo_ssm_env_parameter_path" {
  value = var.n8n_demo_enabled ? module.ssm_demo[0].env_parameter_path : null
}
