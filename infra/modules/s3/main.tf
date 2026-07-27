# Private deploy-artifact bucket used to transfer workflow JSON tars from
# GitHub Actions to EC2 during CI/CD, replacing base64-embedding the tar
# directly into the SSM RunCommand document. That document (parameters +
# script content combined) has a hard ~97KB AWS-side size limit
# (MaxDocumentSizeExceeded); a base64-encoded tar of this repo's workflow
# JSON files alone is already well over that. S3 has no such limit, and each
# EC2 instance already has an IAM role for SSM — extending it with a
# narrowly-scoped s3:GetObject avoids introducing SSH or any new inbound
# network path.
#
# One bucket, shared by both environments, split by prefix (production/,
# demo/) rather than two buckets — bucket names are globally unique and
# per-environment read isolation is enforced by IAM (below), not by bucket
# boundaries, so a second bucket would add naming/output surface without
# adding any real isolation.
#
# Objects are short-lived: CI uploads immediately before triggering the SSM
# deploy and deletes the object right after, with the lifecycle rule below
# as a backstop (in case a run is cancelled mid-deploy and skips its own
# cleanup step). Nothing sensitive belongs in these objects — workflow JSON
# may reference credentials by id/name, but sanitize_workflows.py already
# guarantees no credential values ever reach a workflow file, seeded or
# sanitized, before it gets this far.

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "deploy_artifacts" {
  bucket = "n8n-linkedin-${data.aws_caller_identity.current.account_id}-${var.aws_region}-deploy-artifacts"

  tags = {
    Environment = var.environment
    Service     = "n8n"
  }
}

resource "aws_s3_bucket_public_access_block" "deploy_artifacts" {
  bucket = aws_s3_bucket.deploy_artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "deploy_artifacts" {
  bucket = aws_s3_bucket.deploy_artifacts.id
  versioning_configuration {
    status = "Disabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "deploy_artifacts" {
  bucket = aws_s3_bucket.deploy_artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Backstop only: CI deletes each object itself right after the SSM deploy
# step that consumes it finishes (success or failure). This rule exists so a
# cancelled/crashed CI run can't leave objects around indefinitely.
resource "aws_s3_bucket_lifecycle_configuration" "deploy_artifacts" {
  bucket = aws_s3_bucket.deploy_artifacts.id

  rule {
    id     = "expire-deploy-artifacts"
    status = "Enabled"
    filter {}
    expiration {
      days = 1
    }
  }
}

# ---------------------------------------------------------------------------
# Read access for the EC2 instance roles, scoped to each environment's own
# prefix only — production can never read demo/* and vice versa, mirroring
# every other isolation boundary between the two (see
# docs/demo-environment.md section 4).
# ---------------------------------------------------------------------------

resource "aws_iam_policy" "deploy_artifacts_read_prod" {
  name = "${var.project_name}-deploy-artifacts-read"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.deploy_artifacts.arn}/production/*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "deploy_artifacts_read_prod" {
  role       = var.prod_role_name
  policy_arn = aws_iam_policy.deploy_artifacts_read_prod.arn
}

resource "aws_iam_policy" "deploy_artifacts_read_demo" {
  count = var.demo_role_name != null ? 1 : 0
  name  = "${var.project_name}-demo-deploy-artifacts-read"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.deploy_artifacts.arn}/demo/*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "deploy_artifacts_read_demo" {
  count      = var.demo_role_name != null ? 1 : 0
  role       = var.demo_role_name
  policy_arn = aws_iam_policy.deploy_artifacts_read_demo[0].arn
}

# ---------------------------------------------------------------------------
# Write access for CI. GitHub Actions authenticates as a pre-existing IAM
# identity (AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY secrets) that this
# Terraform config does not create or manage — attach this policy to that
# identity by hand (see docs/aws-production-deployment.md#workflow-seeding).
# Deliberately scoped to PutObject/DeleteObject only (no GetObject, no
# ListBucket, no admin actions), and only under the two prefixes CI actually
# writes to.
# ---------------------------------------------------------------------------

resource "aws_iam_policy" "deploy_artifacts_write_ci" {
  name = "${var.project_name}-deploy-artifacts-write-ci"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = [
          "${aws_s3_bucket.deploy_artifacts.arn}/production/*",
          "${aws_s3_bucket.deploy_artifacts.arn}/demo/*"
        ]
      }
    ]
  })
}
