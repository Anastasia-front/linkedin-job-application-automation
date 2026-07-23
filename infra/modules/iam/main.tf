data "aws_caller_identity" "current" {}

locals {
  path_prefix = coalesce(var.path_prefix, "/${var.project_name}")
  env_path    = "${local.path_prefix}/env"
  ssm_parameter_arns = [
    "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${local.path_prefix}/env",
    "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${local.path_prefix}/env/*",
    "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${local.path_prefix}/nginx/origin_certificate",
    "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${local.path_prefix}/nginx/origin_private_key"
  ]
}

resource "aws_iam_role" "ec2_role" {
  name = "${var.project_name}${var.name_suffix}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = {
    Environment = var.environment
    Service     = var.service
  }
}

resource "aws_iam_policy" "ssm_parameter_read" {
  name = "${var.project_name}${var.name_suffix}-ssm-parameter-read"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath"
        ]
        Resource = local.ssm_parameter_arns
      }
    ]
  })

  tags = {
    Environment = var.environment
    Service     = var.service
  }
}

resource "aws_iam_role_policy_attachment" "ssm_parameter_read" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = aws_iam_policy.ssm_parameter_read.arn
}

resource "aws_iam_role_policy_attachment" "ssm_managed_instance_core" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "profile" {
  name = "${var.project_name}${var.name_suffix}-ec2-profile"
  role = aws_iam_role.ec2_role.name

  tags = {
    Environment = var.environment
    Service     = var.service
  }
}
