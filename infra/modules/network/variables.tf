variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "ssh_allowed_cidrs" {
  type = list(string)
}

variable "vpc_id" {
  type    = string
  default = null
}

variable "service" {
  description = "Value for the Service tag."
  type        = string
  default     = "n8n"
}
