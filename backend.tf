# ==============================================================================
# backend.tf
# ==============================================================================

# ------------------------------------------------------------------------------
# S3 — Shared Artifact Store
# ------------------------------------------------------------------------------
resource "aws_s3_bucket" "artifacts" {
  bucket        = "${var.agency}-${var.team_app_name}-${var.environment}-artifacts-bucket-${random_string.bucket_uid.result}"
  force_destroy = true
  tags          = local.common_tags
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ------------------------------------------------------------------------------
# S3 - Per-environment application buckets
# The Lambda function deposits files into these buckets.
# ------------------------------------------------------------------------------

resource "aws_s3_bucket" "app" {
  for_each      = toset(local.all_envs)
  bucket        = local.app_bucket_names[each.key]
  force_destroy = true

  #tags = local.common_tags_per_env
  tags = { Environment = each.key }
}

resource "aws_s3_bucket_versioning" "app" {
  for_each = toset(local.all_envs)
  bucket   = aws_s3_bucket.app[each.key].id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "app" {
  for_each = toset(local.all_envs)
  bucket   = aws_s3_bucket.app[each.key].id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "app" {
  for_each                = toset(local.all_envs)
  bucket                  = aws_s3_bucket.app[each.key].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Lifecycle rule: auto-expire deposits after 90 days (adjust per environment if needed)
resource "aws_s3_bucket_lifecycle_configuration" "app" {
  for_each = toset(local.all_envs)
  bucket   = aws_s3_bucket.app[each.key].id

  rule {
    id     = "expire-deposits"
    status = "Enabled"
    filter { prefix = "deposits/" }
    expiration { days = 90 }
  }
}
