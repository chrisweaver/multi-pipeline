# ==============================================================================
# outputs.tf
# ==============================================================================

output "pr_pipeline_name" {
  description = "Name of the PR branch pipeline (dev + test)"
  value       = aws_codepipeline.pr.name
}

output "main_pipeline_name" {
  description = "Name of the main branch pipeline (all environments)"
  value       = aws_codepipeline.main.name
}

output "artifact_bucket" {
  description = "S3 bucket used for pipeline artifacts"
  value       = aws_s3_bucket.artifacts.bucket
}

output "app_bucket_names" {
  description = "Map of environment → application S3 bucket name"
  value       = { for env, bucket in aws_s3_bucket.app : env => bucket.bucket }
}

output "lambda_function_names" {
  description = "Map of environment → Lambda function name"
  value       = { for env, fn in aws_lambda_function.app : env => fn.function_name }
}

output "lambda_function_arns" {
  description = "Map of environment → Lambda function ARN"
  value       = { for env, fn in aws_lambda_function.app : env => fn.arn }
}

output "codestar_connection_arn" {
  description = "CodeStar connection ARN — must be ACTIVATED manually in the AWS Console"
  value       = aws_codestarconnections_connection.source.arn
}

output "codestar_connection_status" {
  description = "Current CodeStar connection status (PENDING until activated via Console)"
  value       = aws_codestarconnections_connection.source.connection_status
}
