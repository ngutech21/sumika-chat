#!/bin/sh
set -eu
mkdir -p /logs/verifier
echo 0 > /logs/verifier/reward.txt
completion=/logs/verifier/completion.txt
: > "$completion"
if PYTHONPATH=/app python3 /tests/test_ranges.py "$completion" &&
    [ "$(cat "$completion")" = passed ]; then
    echo 1 > /logs/verifier/reward.txt
fi
