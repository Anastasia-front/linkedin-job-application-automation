variable "project_name" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "environment" {
  description = "Value for the Environment tag applied to the bucket."
  type        = string
  default     = "prod"
}

variable "prod_role_name" {
  description = "IAM role name (module.iam.role_name) granted read-only access to the production/* prefix."
  type        = string
}

variable "demo_role_name" {
  description = "IAM role name (module.iam_demo[0].role_name) granted read-only access to the demo/* prefix. Leave null when the demo environment is disabled — no demo policy/attachment is created."
  type        = string
  default     = null
}
