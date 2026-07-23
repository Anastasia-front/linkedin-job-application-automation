locals {
  n8n_required_env = {
    NODE_ENV            = "production"
    N8N_HOST            = var.public_hostname
    N8N_PROTOCOL        = "https"
    N8N_PORT            = "5678"
    N8N_EDITOR_BASE_URL = "https://${var.public_hostname}/"
    WEBHOOK_URL         = "https://${var.public_hostname}/"
    N8N_PROXY_HOPS      = "1"
  }

  # Demo-only required env, merged with var.n8n_demo_env_values (which carries
  # the demo-only secrets: N8N_ENCRYPTION_KEY, DB_POSTGRESDB_PASSWORD, etc).
  # This map must never be merged with local.n8n_required_env / var.env_values.
  n8n_demo_required_env = {
    NODE_ENV            = "production"
    N8N_HOST            = var.n8n_demo_domain
    N8N_PROTOCOL        = "https"
    N8N_PORT            = "5678"
    N8N_EDITOR_BASE_URL = "https://${var.n8n_demo_domain}/"
    WEBHOOK_URL         = "https://${var.n8n_demo_domain}/"
    N8N_PROXY_HOPS      = "1"
  }
}

module "network" {
  source = "./modules/network"

  project_name      = var.project_name
  environment       = var.environment
  ssh_allowed_cidrs = var.ssh_allowed_cidrs
  vpc_id            = var.vpc_id
}

module "iam" {
  source = "./modules/iam"

  project_name = var.project_name
  aws_region   = var.aws_region
  environment  = var.environment
}

module "ec2" {
  source = "./modules/ec2"

  project_name     = var.project_name
  environment      = var.environment
  key_name         = var.key_name
  ami              = var.ec2_ami
  instance_type    = var.instance_type
  subnet_id        = coalesce(var.subnet_id, module.network.subnet_id)
  security_group   = module.network.ec2_security_group_id
  instance_profile = module.iam.instance_profile_name
  user_data        = file("${path.module}/userdata.sh")
}

module "ssm" {
  source = "./modules/ssm"

  project_name                     = var.project_name
  path_prefix                      = "/${var.project_name}"
  env_values                       = merge(var.env_values, local.n8n_required_env)
  nginx_origin_certificate         = var.nginx_origin_certificate
  nginx_origin_certificate_version = var.nginx_origin_certificate_version
  nginx_origin_private_key         = var.nginx_origin_private_key
  nginx_origin_private_key_version = var.nginx_origin_private_key_version
}

# ---------------------------------------------------------------------------
# Demo environment: fully separate EC2 instance, security group, IAM role,
# Elastic IP and SSM parameter path. Nothing here is shared with the modules
# above. Toggle with var.n8n_demo_enabled.
# ---------------------------------------------------------------------------

module "network_demo" {
  source = "./modules/network"
  count  = var.n8n_demo_enabled ? 1 : 0

  project_name      = var.project_name
  environment       = "demo"
  ssh_allowed_cidrs = var.n8n_demo_allowed_admin_cidrs
  vpc_id            = var.vpc_id
  service           = "n8n"
}

module "iam_demo" {
  source = "./modules/iam"
  count  = var.n8n_demo_enabled ? 1 : 0

  project_name = var.project_name
  aws_region   = var.aws_region
  environment  = "demo"
  name_suffix  = "-demo"
  path_prefix  = "/${var.project_name}/demo"
}

module "ec2_demo" {
  source = "./modules/ec2"
  count  = var.n8n_demo_enabled ? 1 : 0

  project_name     = var.project_name
  environment      = "demo"
  key_name         = coalesce(var.n8n_demo_key_name, var.key_name)
  ami              = var.n8n_demo_ami
  instance_type    = var.n8n_demo_instance_type
  subnet_id        = coalesce(var.n8n_demo_subnet_id, module.network_demo[0].subnet_id)
  security_group   = module.network_demo[0].ec2_security_group_id
  instance_profile = module.iam_demo[0].instance_profile_name
  user_data = templatefile("${path.module}/userdata-demo.tftpl", {
    reset_hour     = var.n8n_demo_reset_hour
    reset_timezone = var.n8n_demo_reset_timezone
  })
  root_volume_size = var.n8n_demo_volume_size
  service          = "n8n"
}

module "ssm_demo" {
  source = "./modules/ssm"
  count  = var.n8n_demo_enabled ? 1 : 0

  project_name                     = var.project_name
  path_prefix                      = "/${var.project_name}/demo"
  env_values                       = merge(var.n8n_demo_env_values, local.n8n_demo_required_env)
  nginx_origin_certificate         = var.n8n_demo_nginx_origin_certificate
  nginx_origin_certificate_version = var.n8n_demo_nginx_origin_certificate_version
  nginx_origin_private_key         = var.n8n_demo_nginx_origin_private_key
  nginx_origin_private_key_version = var.n8n_demo_nginx_origin_private_key_version
}
