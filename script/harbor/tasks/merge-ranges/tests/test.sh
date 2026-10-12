#!/bin/sh
set -eu
mkdir -p /logs/verifier
echo 0 > /logs/verifier/reward.txt
if PYTHONPATH=/app python3 /tests/test_ranges.py; then
    echo 1 > /logs/verifier/reward.txt
fi
