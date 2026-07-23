variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "key_name" {
  type = string
}

variable "ami" {
  type    = string
  default = null
}

variable "instance_type" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "security_group" {
  type = string
}

variable "instance_profile" {
  type = string
}

variable "user_data" {
  description = "Rendered cloud-init user-data content (pass file(...) or templatefile(...) from the caller)."
  type        = string
}

variable "root_volume_size" {
  description = "Root EBS volume size in GiB. Leave null to keep the AMI's default block device (preserves existing production behavior)."
  type        = number
  default     = null
}

variable "service" {
  description = "Value for the Service tag."
  type        = string
  default     = "n8n"
}
