# ==============================================================================
# lambda.tf
# One Lambda function per environment.
# Each function is wired to its environment's S3 bucket via an env var.
# CodePipeline deploys updated code to all functions in scope for the branch.
# ==============================================================================

resource "aws_lambda_function" "app" {
  for_each = toset(local.all_envs)

  function_name    = local.lambda_names[each.key]
  role             = aws_iam_role.lambda_exec[each.key].arn
  runtime          = var.python_runtime
  handler          = var.lambda_handler
  timeout          = var.lambda_timeout
  memory_size      = var.lambda_memory
  filename         = data.archive_file.lambda_placeholder.output_path
  source_code_hash = data.archive_file.lambda_placeholder.output_base64sha256

  environment {
    variables = {
      ENVIRONMENT   = each.key
      TARGET_BUCKET = aws_s3_bucket.app[each.key].bucket
    }
  }

  tags = { Environment = each.key }

  depends_on = [aws_cloudwatch_log_group.lambda]
}

resource "aws_lambda_alias" "live" {
  for_each         = toset(local.all_envs)
  name             = "live"
  function_name    = aws_lambda_function.app[each.key].function_name
  function_version = "$LATEST"
}

# CloudWatch log groups with retention (created before the function to avoid
# the function auto-creating them without a retention policy)
resource "aws_cloudwatch_log_group" "lambda" {
  for_each          = toset(local.all_envs)
  name              = "/aws/lambda/${local.lambda_names[each.key]}"
  retention_in_days = each.key == "prod" ? 90 : 14

  tags = { Environment = each.key }
}


# Lambda execution roles (one per environment)

resource "aws_iam_role" "lambda_exec" {
  for_each           = toset(local.all_envs)
  name               = "${var.team_app_name}-lambda-${each.key}-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json

  tags = { Environment = each.key }
}

# Basic CloudWatch Logs access
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  for_each   = toset(local.all_envs)
  role       = aws_iam_role.lambda_exec[each.key].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Allow each Lambda to write only to its own environment's S3 bucket
resource "aws_iam_role_policy" "lambda_s3" {
  for_each = toset(local.all_envs)
  name     = "s3-deposit"
  role     = aws_iam_role.lambda_exec[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DepositFiles"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket",
        ]
        Resource = [
          aws_s3_bucket.app[each.key].arn,
          "${aws_s3_bucket.app[each.key].arn}/*",
        ]
      }
    ]
  })
}
