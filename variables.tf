# ==============================================================================
# variables.tf
# ==============================================================================

# Project and environment settings

variable "aws_region" {
  description = "Deployment environment to deploy into"
  type        = string
  default     = "us-east-1"

  validation {
    condition     = contains(["us-east-1", "us-east-2"], var.aws_region)
    error_message = "aws_region must be us-east-1 or us-east-2"
  }
}

variable "agency" {
  description = "COV Agency that owns the resources"
  type        = string
  default     = "dbhds"
}

variable "team_app_name" {
  description = "Name of agency application that owns the resource, used as a prefix for all resources"
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9-_]+$", var.team_app_name))
    error_message = "team_app_name must be alphanumeric with hyphens or underscores"
  }
}

variable "environment" {
  description = "Environment for deployment"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "test", "uat", "prod"], var.environment)
    error_message = "environment must be dev, test, uat, or prod"
  }
}

variable "scope" {
  description = "Scope or description of the resource"
  type        = string
}

# Source repository

variable "source_provider" {
  description = "CodeStar connection provider type"
  type        = string
  default     = "GitHub"
}

variable "repo_org" {
  description = "git repository org"
  type        = string
  # default = TODO
}

variable "repo_name" {
  description = "git repository name"
  type        = string
}

variable "repo_branch" {
  description = "Branch that triggers the pipeline"
  type        = string
  default     = "main"
}

variable "main_branch" {
  description = "Name of the production branch that triggers the full four-environment pipeline"
  type        = string
  default     = "main"
}

variable "pr_branch_pattern" {
  description = "Branch name pattern that triggers the PR pipeline (dev+test only); uses CodePipeline glob syntax"
  type        = string
  default     = "refs/pull/*/head"
}

# CodeBuild
variable "source_codeconnections_arn" {
  description = "ARN of the CodeStar / Codeconnections connection for the source repository"
  type        = string
}

# Lambda

variable "python_runtime" {
  description = "Python Lambda runtime identifier"
  type        = string
  default     = "python3.12"
}

variable "lambda_handler" {
  description = "Lambda handler in 'module.function' format"
  type        = string
  default     = "handler.handler"
}

variable "lambda_timeout" {
  description = "Lambda timeout in seconds"
  type        = number
  default     = 30
}

variable "lambda_memory" {
  description = "Lambda memory in MB"
  type        = number
  default     = 128
}
