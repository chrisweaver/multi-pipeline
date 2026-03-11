# ==============================================================================
# pipeline.tf
# CodePipeline and CodeBuild resources, plus IAM roles and policies for the pipeline.
# ==============================================================================

# ------------------------------------------------------------------------------
# Codebuild projects for multi-stage pipelines.
#
# Three project types:
#   1. build   — install deps, lint, package zip
#   2. test    — pytest with JUnit XML reports
#   3. deploy  — update Lambda code per environment (one project per env)
# ------------------------------------------------------------------------------

locals {
  codebuild_image   = "aws/codebuild/standard:7.0"
  codebuild_compute = "BUILD_GENERAL1_SMALL"
}

#
# Build project resource
#

resource "aws_codebuild_project" "build" {
  name          = "${var.team_app_name}-build"
  description   = "Install dependencies and package Lambda zip"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 15

  artifacts { type = "CODEPIPELINE" }

  environment {
    compute_type                = local.codebuild_compute
    image                       = local.codebuild_image
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec/buildspec-build.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.codebuild["build"].name
      stream_name = "build"
    }
  }
}

#
# Test project resource
#

resource "aws_codebuild_project" "test" {
  name          = "${var.team_app_name}-test"
  description   = "Run pytest suite with JUnit XML output"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 15

  artifacts { type = "CODEPIPELINE" }

  environment {
    compute_type                = local.codebuild_compute
    image                       = local.codebuild_image
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec/buildspec-test.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.codebuild["test"].name
      stream_name = "test"
    }
  }
}

#
# Deploy projects (one per environment)
#

resource "aws_codebuild_project" "deploy" {
  for_each      = toset(local.all_envs)
  name          = "${var.team_app_name}-deploy-${each.key}"
  description   = "Deploy Lambda to ${each.key} and verify S3 deposit"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 10

  artifacts { type = "CODEPIPELINE" }

  environment {
    compute_type                = local.codebuild_compute
    image                       = local.codebuild_image
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    environment_variable {
      name  = "ENVIRONMENT"
      value = each.key
    }
    environment_variable {
      name  = "LAMBDA_FUNCTION_NAME"
      value = local.lambda_names[each.key]
    }
    environment_variable {
      name  = "TARGET_BUCKET"
      value = local.app_bucket_names[each.key]
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec/buildspec-deploy-${each.key}.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.codebuild["deploy-${each.key}"].name
      stream_name = "deploy"
    }
  }
}

# CloudWatch Log Groups for CodeBuild

resource "aws_cloudwatch_log_group" "codebuild" {
  for_each = toset(concat(
    ["build", "test"],
    [for env in local.all_envs : "deploy-${env}"]
  ))

  name              = "/aws/codebuild/${var.team_app_name}-${each.key}"
  retention_in_days = 7
}


# ------------------------------------------------------------------------------
# PR Pipeline - triggered by PR / feature branches.
# Deploys to DEV and TEST environments only.
#
# Stage flow:
#   Source → Build → Test → Deploy-Dev → Deploy-Test
# ------------------------------------------------------------------------------

resource "aws_codepipeline" "pr" {
  name     = "${var.team_app_name}-pr-pipeline"
  role_arn = aws_iam_role.codepipeline.arn

  artifact_store {
    location = aws_s3_bucket.artifacts.bucket
    type     = "S3"
  }

  #
  # Stage 1: Source
  #
  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        ConnectionArn        = var.source_codeconnections_arn
        FullRepositoryId     = "${var.repo_org}/${var.repo_name}"
        BranchName           = var.pr_branch_pattern
        OutputArtifactFormat = "CODE_ZIP"
        # DetectChanges left false — PR webhooks fire the trigger;
        # set to true if your provider supports automatic PR detection.
        DetectChanges = "false"
      }
    }
  }

  #
  # Stage 2: Build
  #
  stage {
    name = "Build"

    action {
      name             = "Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source_output"]
      output_artifacts = ["build_output"]

      configuration = {
        ProjectName = aws_codebuild_project.build.name
      }
    }
  }

  #
  # Stage 3: Test
  #
  stage {
    name = "Test"

    action {
      name             = "Test"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["build_output"]
      output_artifacts = ["test_output"]

      configuration = {
        ProjectName = aws_codebuild_project.test.name
      }
    }
  }

  #
  # Stage 4: Deploy to Dev environment
  #
  stage {
    name = "Deploy-Dev"

    action {
      name            = "DeployDev"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["test_output"]
      # No output artifact — deploy is terminal for this stage
      output_artifacts = ["deploy_dev_output"]

      configuration = {
        ProjectName = aws_codebuild_project.deploy["dev"].name
      }
    }
  }

  #
  # Stage 5: Deploy to Test environment
  #
  stage {
    name = "Deploy-Test"

    action {
      name             = "DeployTest"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["deploy_dev_output"]
      output_artifacts = []

      configuration = {
        ProjectName = aws_codebuild_project.deploy["test"].name
      }
    }
  }

  tags = { Pipeline = "pr" }
}


# ------------------------------------------------------------------------------
# Main pipeline, triggered by pushes to the main branch.
# Deploys sequentially to DEV → TEST → UAT → PROD.
#
# Stage flow:
#   Source → Build → Test → Deploy-Dev → Deploy-Test → Deploy-UAT → Deploy-Prod
#
# UAT and Prod deploy stages include a manual approval gate before they run.
# ------------------------------------------------------------------------------

resource "aws_codepipeline" "main" {
  name     = "${var.team_app_name}-main-pipeline"
  role_arn = aws_iam_role.codepipeline.arn

  artifact_store {
    location = aws_s3_bucket.artifacts.bucket
    type     = "S3"
  }

  #
  # Stage 1: Source
  #
  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        ConnectionArn        = var.source_codeconnections_arn
        FullRepositoryId     = "${var.repo_org}/${var.repo_name}"
        BranchName           = var.main_branch
        OutputArtifactFormat = "CODE_ZIP"
        DetectChanges        = "true"
      }
    }
  }

  #
  # Stage 2: Build
  #
  stage {
    name = "Build"

    action {
      name             = "Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source_output"]
      output_artifacts = ["build_output"]

      configuration = {
        ProjectName = aws_codebuild_project.build.name
      }
    }
  }

  #
  # Stage 3: Test
  #
  stage {
    name = "Test"

    action {
      name             = "Test"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["build_output"]
      output_artifacts = ["test_output"]

      configuration = {
        ProjectName = aws_codebuild_project.test.name
      }
    }
  }

  #
  # Stage 4: Deploy → Dev
  #
  stage {
    name = "Deploy-Dev"

    action {
      name             = "DeployDev"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["test_output"]
      output_artifacts = ["deploy_dev_output"]

      configuration = {
        ProjectName = aws_codebuild_project.deploy["dev"].name
      }
    }
  }

  #
  # Stage 5: Deploy → Test
  #
  stage {
    name = "Deploy-Test"

    action {
      name             = "DeployTest"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["deploy_dev_output"]
      output_artifacts = ["deploy_test_output"]

      configuration = {
        ProjectName = aws_codebuild_project.deploy["test"].name
      }
    }
  }

  #
  # Stage 6: Approve UAT promotion
  #
  stage {
    name = "Approve-UAT"

    action {
      name     = "ApproveUAT"
      category = "Approval"
      owner    = "AWS"
      provider = "Manual"
      version  = "1"

      configuration = {
        CustomData = "Please review Test environment results before promoting to UAT."
        # Uncomment and set to send approval notification emails:
        # NotificationArn = aws_sns_topic.approvals.arn
        # ExternalEntityLink = "https://your-test-dashboard.example.com"
      }
    }
  }

  #
  # Stage 7: Deploy → UAT
  #
  stage {
    name = "Deploy-UAT"

    action {
      name             = "DeployUAT"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["deploy_test_output"]
      output_artifacts = ["deploy_uat_output"]

      configuration = {
        ProjectName = aws_codebuild_project.deploy["uat"].name
      }
    }
  }

  #
  # Stage 8: Approve Prod promotion
  #
  stage {
    name = "Approve-Prod"

    action {
      name     = "ApproveProd"
      category = "Approval"
      owner    = "AWS"
      provider = "Manual"
      version  = "1"

      configuration = {
        CustomData = "UAT sign-off complete? Approve to release to Production."
        # NotificationArn = aws_sns_topic.approvals.arn
      }
    }
  }

  #
  # Stage 9: Deploy → Prod
  #
  stage {
    name = "Deploy-Prod"

    action {
      name             = "DeployProd"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["deploy_uat_output"]
      output_artifacts = []

      configuration = {
        ProjectName = aws_codebuild_project.deploy["prod"].name
      }
    }
  }

  tags = { Pipeline = "main" }
}

# ------------------------------------------------------------------------------
# ── Optional: SNS topic for approval notifications ────────────────────────────
# Uncomment, add a subscription, and wire NotificationArn above.
#
# resource "aws_sns_topic" "approvals" {
#   name = "${var.team_app_name}-pipeline-approvals"
# }
#
# resource "aws_sns_topic_subscription" "approval_email" {
#   topic_arn = aws_sns_topic.approvals.arn
#   protocol  = "email"
#   endpoint  = "your-team@example.com"
# }
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# IAM
# ------------------------------------------------------------------------------

#
# Helper: reusable assume-role policy documents
#

data "aws_iam_policy_document" "codepipeline_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codepipeline.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "codebuild_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

#
# CodePipeline role (shared by both pipelines)
#

resource "aws_iam_role" "codepipeline" {
  name               = "${var.team_app_name}-codepipeline-role"
  assume_role_policy = data.aws_iam_policy_document.codepipeline_assume.json
}

resource "aws_iam_role_policy" "codepipeline" {
  name   = "codepipeline-permissions"
  role   = aws_iam_role.codepipeline.id
  policy = data.aws_iam_policy_document.codepipeline_permissions.json
}

data "aws_iam_policy_document" "codepipeline_permissions" {
  # Artifact S3 bucket
  statement {
    sid    = "ArtifactStore"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:GetBucketVersioning",
      "s3:GetObjectVersion",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.artifacts.arn,
      "${aws_s3_bucket.artifacts.arn}/*",
    ]
  }

  # Codeconnection (source)
  statement {
    sid       = "Codeconnection"
    effect    = "Allow"
    actions   = ["codestar-connections:UseConnection"]
    resources = [var.source_codeconnections_arn]
  }

  # Start / inspect CodeBuild jobs (build, test, deploy-*)
  statement {
    sid    = "CodeBuild"
    effect = "Allow"
    actions = [
      "codebuild:BatchGetBuilds",
      "codebuild:StartBuild",
      "codebuild:StopBuild",
    ]
    resources = [
      aws_codebuild_project.build.arn,
      aws_codebuild_project.test.arn,
      aws_codebuild_project.deploy["dev"].arn,
      aws_codebuild_project.deploy["test"].arn,
      aws_codebuild_project.deploy["uat"].arn,
      aws_codebuild_project.deploy["prod"].arn,
    ]
  }

  # PassRole so CodePipeline can hand the CodeBuild role to build jobs
  statement {
    sid       = "PassRole"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [
      aws_iam_role.codebuild.arn
    ]
  }
}

#
# CodeBuild role (shared across all build / test / deploy projects)
#

resource "aws_iam_role" "codebuild" {
  name               = "${var.team_app_name}-codebuild-role"
  assume_role_policy = data.aws_iam_policy_document.codebuild_assume.json
}

resource "aws_iam_role_policy" "codebuild" {
  name   = "codebuild-permissions"
  role   = aws_iam_role.codebuild.id
  policy = data.aws_iam_policy_document.codebuild_permissions.json
}

data "aws_iam_policy_document" "codebuild_permissions" {
  # Artifact S3
  statement {
    sid    = "ArtifactStore"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:GetBucketVersioning",
      "s3:GetObjectVersion",
    ]
    resources = [
      aws_s3_bucket.artifacts.arn,
      "${aws_s3_bucket.artifacts.arn}/*",
    ]
  }

  # CloudWatch Logs
  statement {
    sid    = "CloudWatchLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["arn:${local.partition}:logs:${var.aws_region}:${local.account_id}:log-group:/aws/codebuild/${var.team_app_name}-*"]
  }

  # CodeBuild test reports
  statement {
    sid    = "TestReports"
    effect = "Allow"
    actions = [
      "codebuild:CreateReportGroup",
      "codebuild:CreateReport",
      "codebuild:UpdateReport",
      "codebuild:BatchPutTestCases",
      "codebuild:BatchPutCodeCoverages",
    ]
    resources = ["arn:${local.partition}:codebuild:${var.aws_region}:${local.account_id}:report-group/${var.team_app_name}-*"]
  }

  # Update Lambda function code for any of our functions
  statement {
    sid    = "LambdaUpdateCode"
    effect = "Allow"
    actions = [
      "lambda:UpdateFunctionCode",
      "lambda:GetFunction",
      "lambda:PublishVersion",
      "lambda:UpdateAlias",
      "lambda:GetAlias",
    ]
    resources = [
      for env in local.all_envs :
      "arn:${local.partition}:lambda:${var.aws_region}:${local.account_id}:function:${local.lambda_names[env]}"
    ]
  }

  # Read SSM parameters if the deploy scripts need config values
  statement {
    sid       = "SSMReadOnly"
    effect    = "Allow"
    actions   = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath"]
    resources = ["arn:${local.partition}:ssm:${var.aws_region}:${local.account_id}:parameter/${var.team_app_name}/*"]
  }
}
