data "aws_ami" "ubuntu" {
  count       = var.ami == null ? 1 : 0
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  ami = coalesce(var.ami, data.aws_ami.ubuntu[0].id)
}

resource "aws_instance" "n8n" {
  ami           = local.ami
  instance_type = var.instance_type
  key_name      = var.key_name
  subnet_id     = var.subnet_id
  vpc_security_group_ids = [
    var.security_group
  ]
  iam_instance_profile = var.instance_profile
  user_data            = var.user_data

  # Require IMDSv2 (session-token-backed metadata calls) and limit the hop
  # count so containers cannot reach the metadata endpoint through the
  # default gateway hop from inside Docker's bridge network.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  dynamic "root_block_device" {
    for_each = var.root_volume_size == null ? [] : [var.root_volume_size]
    content {
      volume_size = root_block_device.value
      volume_type = "gp3"
      encrypted   = true
    }
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-n8n"
    Environment = var.environment
    Service     = var.service
  }
}

resource "aws_eip" "n8n" {
  domain = "vpc"

  tags = {
    Name        = "${var.project_name}-${var.environment}-eip"
    Environment = var.environment
    Service     = var.service
  }
}

resource "aws_eip_association" "n8n" {
  instance_id   = aws_instance.n8n.id
  allocation_id = aws_eip.n8n.id
}
