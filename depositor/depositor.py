"""
depositor/handler.py
--------------
Lambda function that deposits a timestamped JSON file into an S3 bucket.

Environment variables (injected by Terraform):
  TARGET_BUCKET  — name of the S3 bucket to deposit into
  ENVIRONMENT    — deployment environment label (dev / test / uat / prod)
"""

from __future__ import annotations

import json
import logging
import os
import uuid
from datetime import datetime, timezone
from typing import Any

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

# ---------------------------------------------------------------------------
# Module-level clients (reused across warm invocations)
# ---------------------------------------------------------------------------
_s3_client = None


def _get_s3() -> Any:
    global _s3_client
    if _s3_client is None:
        _s3_client = boto3.client("s3")
    return _s3_client


# ---------------------------------------------------------------------------
# Handler
# ---------------------------------------------------------------------------

def handler(event: dict, context: Any) -> dict:
    """
    Deposit a JSON file into TARGET_BUCKET and return the S3 key.

    Returns:
        {
            "statusCode": 200,
            "key": "deposits/2024-01-15T12:00:00.000000+00:00__<uuid>.json",
            "bucket": "<TARGET_BUCKET>",
            "environment": "<ENVIRONMENT>"
        }

    Raises:
        EnvironmentError: if TARGET_BUCKET is not set.
        RuntimeError:     if the S3 put fails.
    """
    bucket = os.environ.get("TARGET_BUCKET", "").strip()
    environment = os.environ.get("ENVIRONMENT", "unknown").strip()

    if not bucket:
        raise EnvironmentError("TARGET_BUCKET environment variable is not set")

    now = datetime.now(tz=timezone.utc)
    deposit_id = str(uuid.uuid4())
    key = f"deposits/{now.isoformat()}__{deposit_id}.json"

    payload = {
        "deposit_id": deposit_id,
        "environment": environment,
        "timestamp": now.isoformat(),
        "event": event,
        "lambda_request_id": getattr(context, "aws_request_id", "local"),
    }

    logger.info("Depositing to s3://%s/%s", bucket, key)

    try:
        _get_s3().put_object(
            Bucket=bucket,
            Key=key,
            Body=json.dumps(payload, indent=2),
            ContentType="application/json",
            Metadata={
                "environment": environment,
                "deposit-id": deposit_id,
            },
        )
    except ClientError as exc:
        error_code = exc.response["Error"]["Code"]
        logger.error("S3 put failed [%s]: %s", error_code, exc)
        raise RuntimeError(f"Failed to deposit file into s3://{bucket}/{key}: {exc}") from exc

    logger.info("Deposit complete: s3://%s/%s", bucket, key)

    return {
        "statusCode": 200,
        "key": key,
        "bucket": bucket,
        "environment": environment,
        "deposit_id": deposit_id,
    }
