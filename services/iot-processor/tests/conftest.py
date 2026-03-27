"""
Patch env vars and confluent_kafka before app.py is imported so that
module-level Consumer/Producer construction doesn't fail in unit tests.
"""
import os
import sys
from unittest.mock import MagicMock

# Required env vars read at module level in app.py
os.environ.setdefault("KAFKA_BOOTSTRAP_SERVERS", "localhost:9092")
os.environ.setdefault("KAFKA_USERNAME", "test_user")
os.environ.setdefault("KAFKA_PASSWORD", "test_pass")

# Mock confluent_kafka so the library is not required in the test environment
sys.modules.setdefault("confluent_kafka", MagicMock())
