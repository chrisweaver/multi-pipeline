# AWS CodePipeline → Python Lambda → S3 — Terraform

A production-ready CI/CD pipeline that deploys a Python Lambda which deposits
files into environment-specific S3 buckets, with branch-aware promotion rules.

---

## Architecture

```
                     ┌─────────────────────────────────────────────────┐
  PR branch ──────▶  │  PR Pipeline                                    │
                     │  Source → Build → Test → Deploy-Dev → Deploy-Test│
                     └─────────────────────────────────────────────────┘

                     ┌────────────────────────────────────────────────────────────────────────────┐
  main branch ─────▶ │  Main Pipeline                                                              │
                     │  Source → Build → Test → Deploy-Dev → Deploy-Test → [Approve] →            │
                     │  Deploy-UAT → [Approve] → Deploy-Prod                                       │
                     └────────────────────────────────────────────────────────────────────────────┘
```

### Environment matrix

| Branch | Dev | Test | UAT | Prod |
|--------|:---:|:----:|:---:|:----:|
| PR     | ✅  | ✅   | ❌  | ❌   |
| main   | ✅  | ✅   | ✅  | ✅   |

### Resources created

| Resource | Count | Notes |
|----------|-------|-------|
| CodePipeline | 2 | pr-pipeline, main-pipeline |
| CodeBuild projects | 6 | build, test, deploy-dev/test/uat/prod |
| Lambda functions | 4 | one per environment |
| S3 buckets | 5 | 1 artifact store + 4 app buckets |
| IAM roles | 6 | codepipeline, codebuild, lambda×4 |
| CloudWatch log groups | 8 | lambda×4 + codebuild×4 |

---

## Prerequisites

| Tool | Version |
|------|---------|
| Terraform | ≥ 1.5.0 |
| AWS CLI | ≥ 2.x |
| Python | 3.12 (for local testing) |

---

## Quick Start

```bash
# 1. Copy and fill in your variables
cp terraform.tfvars.example terraform.tfvars
vim terraform.tfvars   # set repo_owner, repo_name, etc.

# 2. Initialise and apply
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

---

## ⚠️  Required: Activate the CodeStar Connection

After `terraform apply`, the CodeStar Connection is in **PENDING** status.
The pipelines will not run until you activate it:

1. Open **AWS Console → Developer Tools → Settings → Connections**
2. Select `<project_name>-connection`
3. Click **Update pending connection** and complete the OAuth flow
4. Status changes to **Available** — pipelines will now trigger on push/PR

---

## Project Layout

```
terraform-cicd-python/
├── main.tf                        # Providers, data sources, locals
├── variables.tf                   # Input variables
├── outputs.tf                     # Stack outputs
├── s3.tf                          # Artifact bucket + 4 app buckets
├── lambda.tf                      # 4 Lambda functions + aliases
├── codebuild.tf                   # Build / test / deploy CodeBuild projects
├── pipeline_pr.tf                 # PR pipeline (dev + test)
├── pipeline_main.tf               # Main pipeline (all 4 envs + approvals)
├── iam.tf                         # All IAM roles and policies
├── requirements.txt               # Lambda runtime dependencies
├── requirements-dev.txt           # Test/lint dependencies
├── terraform.tfvars.example
├── src/
│   └── handler.py                 # Lambda function source
├── tests/
│   ├── unit/
│   │   └── test_handler.py        # Unit tests (moto-mocked S3)
│   └── integration/
│       └── test_deposit_flow.py   # Integration tests (moto-mocked S3)
└── buildspec/
    ├── buildspec-build.yml        # Install, lint, package zip
    ├── buildspec-test.yml         # pytest + JUnit XML reports
    ├── buildspec-deploy-dev.yml
    ├── buildspec-deploy-test.yml
    ├── buildspec-deploy-uat.yml
    └── buildspec-deploy-prod.yml
```

---

## Pipeline Stages

### PR Pipeline (dev + test)

| # | Stage | What happens |
|---|-------|-------------|
| 1 | **Source** | Triggered by PR branch push via CodeStar connection |
| 2 | **Build** | `pip install`, `flake8` lint, `zip` Lambda package |
| 3 | **Test** | `pytest` unit + integration; JUnit XML published to CodeBuild |
| 4 | **Deploy-Dev** | `update-function-code` → smoke invoke → S3 object verified |
| 5 | **Deploy-Test** | Same as above for test environment |

### Main Pipeline (all environments)

| # | Stage | What happens |
|---|-------|-------------|
| 1–5 | Same as PR pipeline | ... |
| 6 | **Approve-UAT** | Manual approval gate (console/SNS) |
| 7 | **Deploy-UAT** | Deploy + smoke test on UAT |
| 8 | **Approve-Prod** | Manual approval gate |
| 9 | **Deploy-Prod** | Deploy + smoke test on Prod |

---

## Lambda Function

`src/handler.py` deposits a timestamped JSON file into `TARGET_BUCKET`:

```
s3://<TARGET_BUCKET>/deposits/<ISO-timestamp>__<uuid>.json
```

**Response shape:**
```json
{
  "statusCode": 200,
  "key": "deposits/2024-01-15T12:00:00.123456+00:00__<uuid>.json",
  "bucket": "file-depositor-app-prod-<account-id>",
  "environment": "prod",
  "deposit_id": "<uuid>"
}
```

---

## Running Tests Locally

```bash
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt -r requirements-dev.txt

# Unit tests
pytest tests/unit/ -v

# Integration tests
pytest tests/integration/ -v

# All tests with coverage
pytest tests/ --cov=src --cov-report=term-missing
```

---

## Enabling Approval Notifications

Uncomment the SNS resources in `pipeline_main.tf` and wire `NotificationArn`:

```hcl
resource "aws_sns_topic" "approvals" {
  name = "${var.project_name}-pipeline-approvals"
}

resource "aws_sns_topic_subscription" "approval_email" {
  topic_arn = aws_sns_topic.approvals.arn
  protocol  = "email"
  endpoint  = "your-team@example.com"
}
```

Then in each approval action:
```hcl
configuration = {
  NotificationArn = aws_sns_topic.approvals.arn
  CustomData      = "Approve to promote to UAT"
}
```

---

## Tear Down

```bash
terraform destroy
```

S3 buckets are created with `force_destroy = true` so Terraform will empty
and delete them automatically. Lambda functions and CodeBuild logs are also
fully removed.
