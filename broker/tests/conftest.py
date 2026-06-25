"""Set the required env BEFORE app.py is imported.

app.py reads its config (GH_*, BROKER_SECRET, key) at import time and fails fast if any is
missing, so the test suite must populate the environment first. The functional tests never reach
GitHub, so a placeholder private key is sufficient. RATE_LIMIT is set high here so ordinary
auth/health tests don't trip it; the rate-limit tests install their own small limiter.
"""
import os

os.environ.setdefault("GH_APP_ID", "123456")
os.environ.setdefault("GH_INSTALLATION_ID", "7654321")
os.environ.setdefault("GH_ORG", "test-org")
os.environ.setdefault("BROKER_SECRET", "test-broker-secret")
os.environ.setdefault("GH_APP_PRIVATE_KEY", "placeholder-not-a-real-key")
os.environ.setdefault("RATE_LIMIT_PER_MINUTE", "1000")
