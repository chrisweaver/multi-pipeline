# ==============================================================================
# main.tf
# Providers, data sources, and shared locals.
# ==============================================================================

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}

# ------------------------------------------------------------------------------
# Common resources
# ------------------------------------------------------------------------------
# Create a 4 character random string, used for S3 bucket suffix
resource "random_string" "bucket_uid" {
  length  = 4
  upper   = false
  numeric = false
  special = false
}

# ------------------------------------------------------------------------------
# Data sources
# ------------------------------------------------------------------------------
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# Placeholder zip — Terraform needs an initial artifact to create the Lambda.
# CodePipeline will overwrite this on every successful deploy.
data "archive_file" "lambda_placeholder" {
  type        = "zip"
  output_path = "${path.module}/.placeholder.zip"

  source {
    content  = <<-PYTHON
      import json, os, boto3, datetime

      def handler(event, context):
          bucket = os.environ["TARGET_BUCKET"]
          key    = f"deposits/{datetime.datetime.utcnow().isoformat()}.json"
          boto3.client("s3").put_object(
              Bucket=bucket,
              Key=key,
              Body=json.dumps({"status": "placeholder", "event": event}),
              ContentType="application/json",
          )
          return {"statusCode": 200, "key": key}
    PYTHON
    filename = "handler.py"
  }
}

# ------------------------------------------------------------------------------
# Locals
# ------------------------------------------------------------------------------
locals {
  # All four environments
  all_envs = ["dev", "test", "uat", "prod"]

  # Environments reachable from PR pipelines
  pr_envs = ["dev", "test"]

  # Environments reachable from main pipeline (superset)
  main_envs = ["dev", "test", "uat", "prod"]

  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  common_tags = {
    Agency      = var.agency
    Project     = var.team_app_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }

  # Convenience: build a map of env → app-bucket name
  app_bucket_names = {
    for env in local.all_envs :
    env => "${var.agency}-${var.team_app_name}-${env}-app-bucket-${random_string.bucket_uid.result}"
  }

  # Convenience: build a map of env → Lambda function name
  lambda_names = {
    for env in local.all_envs :
    env => "${var.agency}-${var.team_app_name}-${env}-lambda"
  }
}