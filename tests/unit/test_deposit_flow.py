"""
tests/integration/test_deposit_flow.py
---------------------------------------
Integration tests that exercise the full deposit flow end-to-end
using moto-mocked AWS services. Validates the Lambda handler behaviour
as observed from the outside (S3 object presence, content, metadata).
"""

from __future__ import annotations

import importlib
import json
import os
import sys
import unittest
from datetime import timezone

import boto3
import pytest
from moto import mock_aws


PACKAGE = "depositor"
MODULE = "depositor"
BUCKET = "integration-test-bucket"
REGION = "us-east-1"

# Ensure package/module is importable
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", f"{PACKAGE}"))
test_module = importlib.import_module(MODULE, package=PACKAGE)

def _configure_aws_env():
    os.environ.update({
        "TARGET_BUCKET": BUCKET,
        "ENVIRONMENT": "test",
        "AWS_DEFAULT_REGION": REGION,
        "AWS_ACCESS_KEY_ID": "testing",
        "AWS_SECRET_ACCESS_KEY": "testing",
        "AWS_SECURITY_TOKEN": "testing",
        "AWS_SESSION_TOKEN": "testing",
    })


def _reload_handler():
    """Reload module to get a clean execution environment.
    """
    importlib.reload(test_module)
    return test_module.handler


@mock_aws
class TestDepositFlow(unittest.TestCase):

    def setUp(self):
        _configure_aws_env()
        self.s3 = boto3.client("s3", region_name=REGION)
        self.s3.create_bucket(Bucket=BUCKET)
        self.handler = _reload_handler()

    def tearDown(self):
        for key in ("TARGET_BUCKET", "ENVIRONMENT"):
            os.environ.pop(key, None)

    # ── Full happy-path flow ───────────────────────────────────────────────────

    def test_deposit_object_exists_in_s3(self):
        """After invocation, the S3 object must be present and readable."""
        result = self.handler({"integration": True}, None)
        key = result["key"]

        response = self.s3.get_object(Bucket=BUCKET, Key=key)
        assert response["ResponseMetadata"]["HTTPStatusCode"] == 200

    def test_deposit_body_is_valid_json(self):
        result = self.handler({}, None)
        obj = self.s3.get_object(Bucket=BUCKET, Key=result["key"])
        body = json.loads(obj["Body"].read())
        assert isinstance(body, dict)

    def test_deposit_body_has_correct_environment(self):
        result = self.handler({}, None)
        obj = self.s3.get_object(Bucket=BUCKET, Key=result["key"])
        body = json.loads(obj["Body"].read())
        assert body["environment"] == "test"

    def test_deposit_ids_are_consistent(self):
        """deposit_id in response == deposit_id in S3 body."""
        result = self.handler({}, None)
        obj = self.s3.get_object(Bucket=BUCKET, Key=result["key"])
        body = json.loads(obj["Body"].read())
        assert body["deposit_id"] == result["deposit_id"]

    def test_multiple_deposits_all_land_in_s3(self):
        """Ten sequential invocations should each create a distinct S3 object."""
        keys = set()
        for i in range(10):
            r = self.handler({"run": i}, None)
            keys.add(r["key"])
        assert len(keys) == 10

        # Confirm all objects exist
        listed = self.s3.list_objects_v2(Bucket=BUCKET, Prefix="deposits/")
        found_keys = {obj["Key"] for obj in listed.get("Contents", [])}
        assert keys.issubset(found_keys)

    def test_s3_metadata_environment_tag(self):
        result = self.handler({}, None)
        head = self.s3.head_object(Bucket=BUCKET, Key=result["key"])
        assert head["Metadata"].get("environment") == "test"

    def test_timestamp_is_utc_aware(self):
        result = self.handler({}, None)
        obj = self.s3.get_object(Bucket=BUCKET, Key=result["key"])
        body = json.loads(obj["Body"].read())
        from datetime import datetime
        ts = datetime.fromisoformat(body["timestamp"])
        assert ts.tzinfo is not None


if __name__ == "__main__":
    unittest.main()
