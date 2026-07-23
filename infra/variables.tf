variable "aws_region" {
  type    = string
  default = "eu-central-1"
}

variable "project_name" {
  type    = string
  default = "linkedin-job-application-automation"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "public_hostname" {
  type    = string
  default = "n8n.ai-automation-platform.com"
}

variable "key_name" {
  type = string
}

variable "ssh_allowed_cidrs" {
  description = "Restricted CIDR ranges allowed to SSH to the EC2 instance."
  type        = list(string)
}

variable "vpc_id" {
  description = "VPC for the EC2 instance. Leave null to use the default VPC."
  type        = string
  default     = null
}

variable "subnet_id" {
  description = "Subnet for the EC2 instance. Leave null to use the first default VPC subnet."
  type        = string
  default     = null
}

variable "ec2_ami" {
  description = "Optional Ubuntu AMI override. Leave null to use the latest Ubuntu 24.04 LTS amd64 AMI."
  type        = string
  default     = null
}

variable "instance_type" {
  type    = string
  default = "t3.small"
}

variable "env_values" {
  description = "Application environment values stored under /linkedin-job-application-automation/env."
  type        = map(string)
  sensitive   = true
}

variable "nginx_origin_certificate" {
  type        = string
  description = "Cloudflare Origin Certificate PEM for n8n.ai-automation-platform.com or an approved wildcard."
  sensitive   = true
}

variable "nginx_origin_certificate_version" {
  type        = number
  description = "Increment when rotating nginx_origin_certificate because value_wo is write-only."
  default     = 1
}

variable "nginx_origin_private_key" {
  type        = string
  description = "Cloudflare Origin private key PEM."
  sensitive   = true
}

variable "nginx_origin_private_key_version" {
  type        = number
  description = "Increment when rotating nginx_origin_private_key because value_wo is write-only."
  default     = 1
}

# ---------------------------------------------------------------------------
# Demo environment (public, editable, daily-reset n8n instance)
# ---------------------------------------------------------------------------

variable "n8n_demo_enabled" {
  description = "Whether to provision the public demo n8n environment. Disabled by default so the demo stack is an explicit opt-in."
  type        = bool
  default     = false
}

variable "n8n_demo_instance_type" {
  type    = string
  default = "t3.small"
}

variable "n8n_demo_domain" {
  description = "Public hostname for the demo n8n instance."
  type        = string
  default     = "demo-n8n.ai-automation-platform.com"
}

variable "n8n_demo_volume_size" {
  description = "Root EBS volume size (GiB) for the demo instance. The demo volume is always encrypted."
  type        = number
  default     = 20
}

variable "n8n_demo_reset_hour" {
  description = "Local hour (0-23, Europe/Paris by default) at which the daily demo reset runs."
  type        = number
  default     = 4
}

variable "n8n_demo_reset_timezone" {
  description = "IANA timezone used for the daily demo reset schedule and the demo host clock."
  type        = string
  default     = "Europe/Paris"
}

variable "n8n_demo_allowed_admin_cidrs" {
  description = "CIDR ranges allowed to SSH to the demo EC2 instance. Leave empty to disable SSH ingress entirely (SSM Session Manager remains available)."
  type        = list(string)
  default     = []
}

variable "n8n_demo_key_name" {
  description = "SSH key pair name for the demo instance. Leave null to reuse key_name."
  type        = string
  default     = null
}

variable "n8n_demo_ami" {
  description = "Optional Ubuntu AMI override for the demo instance. Leave null to use the latest Ubuntu 24.04 LTS amd64 AMI."
  type        = string
  default     = null
}

variable "n8n_demo_subnet_id" {
  description = "Subnet for the demo EC2 instance. Leave null to use the first default VPC subnet."
  type        = string
  default     = null
}

variable "n8n_demo_env_values" {
  description = <<-EOT
    Demo-only application environment values stored under /<project_name>/demo/env,
    e.g. N8N_ENCRYPTION_KEY, DB_POSTGRESDB_PASSWORD, DEMO_USER_EMAIL, DEMO_USER_PASSWORD.
    Must never contain production secrets.
  EOT
  type        = map(string)
  sensitive   = true
  default     = {}
}

variable "n8n_demo_nginx_origin_certificate" {
  description = "Cloudflare Origin Certificate PEM for the demo hostname. Required when n8n_demo_enabled = true."
  type        = string
  sensitive   = true
  default     = ""
}

variable "n8n_demo_nginx_origin_certificate_version" {
  type    = number
  default = 1
}

variable "n8n_demo_nginx_origin_private_key" {
  description = "Cloudflare Origin private key PEM for the demo hostname."
  type        = string
  sensitive   = true
  default     = ""
}

variable "n8n_demo_nginx_origin_private_key_version" {
  type    = number
  default = 1
}
