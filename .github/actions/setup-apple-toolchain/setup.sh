#!/usr/bin/env bash

set -euo pipefail

action_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
# versions.env is resolved relative to this script at runtime.
# shellcheck disable=SC1091
source "$action_directory/versions.env"

: "${XCODE_VERSION:?Missing XCODE_VERSION}"
: "${XCODE_BUILD_VERSION:?Missing XCODE_BUILD_VERSION}"
: "${SWIFT_VERSION:?Missing SWIFT_VERSION}"
: "${MACOS_SDK_VERSION:?Missing MACOS_SDK_VERSION}"

named_developer_directory="/Applications/Xcode_${XCODE_VERSION}.app/Contents/Developer"

if [[ "${GITHUB_ACTIONS:-false}" == "true" ]]; then
  developer_directory="$named_developer_directory"
elif [[ -n "${DEVELOPER_DIR:-}" ]]; then
  developer_directory="$DEVELOPER_DIR"
elif [[ -d "$named_developer_directory" ]]; then
  developer_directory="$named_developer_directory"
else
  developer_directory="$(xcode-select -p)"
fi

if [[ ! -d "$developer_directory" ]]; then
  printf 'Expected Xcode developer directory does not exist: %s\n' "$developer_directory" >&2
  exit 1
fi

export DEVELOPER_DIR="$developer_directory"

xcode_output="$(xcodebuild -version)"
swift_output="$(xcrun swift --version 2>&1)"
macos_sdk_version="$(xcrun --sdk macosx --show-sdk-version)"

xcode_version="$(printf '%s\n' "$xcode_output" | sed -n 's/^Xcode //p')"
xcode_build_version="$(printf '%s\n' "$xcode_output" | sed -n 's/^Build version //p')"
swift_version="$(printf '%s\n' "$swift_output" | sed -E -n 's/.*Apple Swift version ([^ ]+).*/\1/p')"

verify_version() {
  local tool_name="$1"
  local actual_version="$2"
  local expected_version="$3"

  if [[ "$actual_version" != "$expected_version" ]]; then
    printf 'Expected %s %s, found %s.\n' \
      "$tool_name" "$expected_version" "${actual_version:-unknown}" >&2
    exit 1
  fi
}

verify_version "Xcode" "$xcode_version" "$XCODE_VERSION"
verify_version "Xcode build" "$xcode_build_version" "$XCODE_BUILD_VERSION"
verify_version "Apple Swift" "$swift_version" "$SWIFT_VERSION"
verify_version "macOS SDK" "$macos_sdk_version" "$MACOS_SDK_VERSION"

cache_key="xcode-${XCODE_VERSION}-${XCODE_BUILD_VERSION}-swift-${SWIFT_VERSION}-macos-sdk-${MACOS_SDK_VERSION}"

printf 'Developer directory: %s\n' "$DEVELOPER_DIR"
printf 'Runner architecture: %s\n' "$(uname -m)"
printf '%s\n' "$xcode_output"
printf '%s\n' "$swift_output"
printf 'macOS SDK %s\n' "$macos_sdk_version"
printf 'Toolchain cache key: %s\n' "$cache_key"

if [[ -n "${GITHUB_ENV:-}" ]]; then
  printf 'DEVELOPER_DIR=%s\n' "$DEVELOPER_DIR" >> "$GITHUB_ENV"
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'cache-key=%s\n' "$cache_key" >> "$GITHUB_OUTPUT"
fi
