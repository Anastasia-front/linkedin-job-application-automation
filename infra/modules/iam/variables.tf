variable "project_name" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "name_suffix" {
  description = "Appended to IAM role/policy/instance-profile names so a second environment (e.g. demo) can reuse this module without colliding with production resources. Defaults to empty to preserve existing production resource names."
  type        = string
  default     = ""
}

variable "path_prefix" {
  description = "SSM parameter path prefix this role is allowed to read (env vars under <path_prefix>/env/* and TLS material under <path_prefix>/nginx/*). Defaults to /<project_name>, matching existing production behavior."
  type        = string
  default     = null
}

variable "service" {
  description = "Value for the Service tag applied to IAM resources."
  type        = string
  default     = "n8n"
}

variable "environment" {
  description = "Value for the Environment tag applied to IAM resources."
  type        = string
  default     = "prod"
}
