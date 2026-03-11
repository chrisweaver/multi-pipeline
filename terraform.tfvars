# ==============================================================================
# Project variables
# ==============================================================================

aws_region    = "us-east-1"
team_app_name = "bogusapp-multi"
environment   = "dev"
scope         = "myscope"

# Source repository
repo_org    = "chrisweaver"
repo_name   = "multi-pipeline"
repo_branch = "master"

# Pipeline
#source_codeconnections_arn = "arn:aws:codeconnections:us-east-1:093597283188:connection/0801356d-f2c4-46fd-b210-cc4d28bbf8b9"
source_codeconnections_arn = "arn:aws:codeconnections:us-east-1:093597283188:connection/546906ef-b09e-4d21-bea2-9c07960c9d8a"

# Lambda
lambda_handler = "depositor.depositor"
