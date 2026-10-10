#!/usr/bin/env bash

set -euo pipefail

xcrun --kill-cache
if xcrun --sdk macosx metal --version; then
  exit 0
fi

xcodebuild -downloadComponent metalToolchain

# Component registration can lag behind the download; discard cached placeholders.
for attempt in {1..12}; do
  xcrun --kill-cache
  if xcrun --sdk macosx metal --version; then
    exit 0
  fi
  if [[ "$attempt" -lt 12 ]]; then
    printf 'Waiting for Metal Toolchain registration (%s/12)...\n' "$attempt"
    sleep 5
  fi
done

printf '::error::Metal Toolchain was downloaded but is unavailable for %s.\n' \
  "${DEVELOPER_DIR:-the selected Xcode}" >&2
exit 1
