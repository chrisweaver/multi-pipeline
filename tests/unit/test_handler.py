"""
tests/unit/test_handler.py
--------------------------
Unit tests for handler.py using moto to mock S3.
No real AWS credentials or resources are required.
"""

from __future__ import annotations

import importlib
import json
import os
import sys
import types
import unittest
from unittest.mock import MagicMock, patch

import boto3
import pytest
from moto import mock_aws

PACKAGE = "depositor"
MODULE = "depositor"

# Ensure package/module is importable
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", f"{PACKAGE}"))
test_module = importlib.import_module(MODULE, package=PACKAGE)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_context(request_id: str = "test-request-id") -> MagicMock:
    ctx = MagicMock()
    ctx.aws_request_id = request_id
    return ctx


def _reload_handler():
    """Reload the handler module so module-level boto3 clients are re-created
    within the moto mock context."""
    importlib.reload(test_module)
    return test_module.handler


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@mock_aws
class TestHandler(unittest.TestCase):

    BUCKET = "test-deposit-bucket"

    def setUp(self):
        """Create a mock S3 bucket and configure env vars before each test."""
        os.environ["TARGET_BUCKET"] = self.BUCKET
        os.environ["ENVIRONMENT"] = "test"
        os.environ["AWS_DEFAULT_REGION"] = "us-east-1"
        os.environ["AWS_ACCESS_KEY_ID"] = "testing"
        os.environ["AWS_SECRET_ACCESS_KEY"] = "testing"
        os.environ["AWS_SECURITY_TOKEN"] = "testing"
        os.environ["AWS_SESSION_TOKEN"] = "testing"

        self.s3 = boto3.client("s3", region_name="us-east-1")
        self.s3.create_bucket(Bucket=self.BUCKET)

        self.handler = _reload_handler()

    def tearDown(self):
        for key in ("TARGET_BUCKET", "ENVIRONMENT"):
            os.environ.pop(key, None)

    # ── Happy path ─────────────────────────────────────────────────────────────

    def test_returns_200_on_success(self):
        result = self.handler({}, _make_context())
        assert result["statusCode"] == 200

    def test_response_contains_expected_keys(self):
        result = self.handler({"source": "unit-test"}, _make_context())
        for field in ("key", "bucket", "environment", "deposit_id"):
            assert field in result, f"Missing field: {field}"

    def test_bucket_name_in_response(self):
        result = self.handler({}, _make_context())
        assert result["bucket"] == self.BUCKET

    def test_environment_in_response(self):
        result = self.handler({}, _make_context())
        assert result["environment"] == "test"

    def test_object_deposited_in_s3(self):
        result = self.handler({}, _make_context())
        key = result["key"]
        obj = self.s3.get_object(Bucket=self.BUCKET, Key=key)
        body = json.loads(obj["Body"].read())
        assert body["environment"] == "test"
        assert "deposit_id" in body
        assert "timestamp" in body

    def test_key_is_under_deposits_prefix(self):
        result = self.handler({}, _make_context())
        assert result["key"].startswith("deposits/")

    def test_event_stored_in_body(self):
        event = {"pipeline": "cicd", "run": 42}
        result = self.handler(event, _make_context())
        key = result["key"]
        obj = self.s3.get_object(Bucket=self.BUCKET, Key=key)
        body = json.loads(obj["Body"].read())
        assert body["event"] == event

    def test_each_invocation_has_unique_key(self):
        result1 = self.handler({}, _make_context())
        result2 = self.handler({}, _make_context())
        assert result1["key"] != result2["key"]

    def test_s3_object_content_type_is_json(self):
        result = self.handler({}, _make_context())
        head = self.s3.head_object(Bucket=self.BUCKET, Key=result["key"])
        assert head["ContentType"] == "application/json"

    # ── Error cases ────────────────────────────────────────────────────────────

    def test_raises_if_target_bucket_not_set(self):
        del os.environ["TARGET_BUCKET"]
        with pytest.raises(EnvironmentError, match="TARGET_BUCKET"):
            self.handler({}, _make_context())

    def test_raises_on_s3_client_error(self):
        """Simulate an S3 failure (bucket doesn't exist)."""
        os.environ["TARGET_BUCKET"] = "non-existent-bucket-xyz"
        with pytest.raises(RuntimeError):
            self.handler({}, _make_context())


if __name__ == "__main__":
    unittest.main()
