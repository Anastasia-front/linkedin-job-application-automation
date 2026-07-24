output "bucket" {
  value       = aws_s3_bucket.deploy_artifacts.bucket
  description = "Set as the DEPLOY_ARTIFACTS_BUCKET GitHub Actions repository variable."
}

output "bucket_arn" {
  value = aws_s3_bucket.deploy_artifacts.arn
}

output "write_ci_policy_arn" {
  value       = aws_iam_policy.deploy_artifacts_write_ci.arn
  description = "Attach this policy to the IAM identity behind the AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY GitHub secrets (manual step — that identity isn't managed by this Terraform config)."
}
