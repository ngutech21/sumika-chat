#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
source "$script_dir/uv-release.sh"
repo_root="${SRCROOT:-$(dirname "$script_dir")}"
cache_dir="$repo_root/.build/uv/$SUMIKA_UV_VERSION/$SUMIKA_UV_SHA256"
archive="$cache_dir/$SUMIKA_UV_ARCHIVE"
mkdir -p "$cache_dir"
staging="$(mktemp -d "$cache_dir/staging.XXXXXX")"
trap 'rm -rf "$staging"' EXIT

verify_archive() {
  test -f "$1" && test "$(shasum -a 256 "$1" | cut -d ' ' -f 1)" = "$SUMIKA_UV_SHA256"
}

if ! verify_archive "$archive"; then
  if [ "${SUMIKA_UV_OFFLINE:-0}" = "1" ]; then
    echo "error: uv $SUMIKA_UV_VERSION is not cached or its checksum is invalid. Build once online to populate $cache_dir." >&2
    exit 1
  fi
  echo "Downloading pinned uv $SUMIKA_UV_VERSION for Sumika"
  curl --fail --location --proto '=https' --tlsv1.2 --retry 2 --connect-timeout 15 --max-time 180 \
    "$SUMIKA_UV_URL" -o "$staging/$SUMIKA_UV_ARCHIVE"
  verify_archive "$staging/$SUMIKA_UV_ARCHIVE" || { echo "error: uv checksum mismatch." >&2; exit 1; }
  mv -f "$staging/$SUMIKA_UV_ARCHIVE" "$archive"
fi

tar -xzf "$archive" -C "$staging"
uv_source="$staging/uv-aarch64-apple-darwin/uv"
test -x "$uv_source"
test "$("$uv_source" --version | awk '{print $2}')" = "$SUMIKA_UV_VERSION"
if [ "${1:-}" = "--prepare" ]; then
  exit 0
fi

uv_target="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers/uv"
mkdir -p "$(dirname "$uv_target")"
install -m 755 "$uv_source" "$uv_target"
resources="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
mkdir -p "$resources"
cp "$script_dir/uv-LICENSE-MIT.txt" "$resources/uv-LICENSE-MIT.txt"

if [ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ]; then
  identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
  if [ -z "$identity" ]; then identity="-"; fi
  if [ "$identity" = "-" ]; then
    codesign --force --sign - "$uv_target"
  else
    # Only distribution signing needs Apple's timestamp service; development
    # builds must remain usable offline with a cached archive.
    timestamp_flag=--timestamp=none
    case "${EXPANDED_CODE_SIGN_IDENTITY_NAME:-$identity}" in
      "Developer ID Application:"*) timestamp_flag=--timestamp ;;
    esac
    codesign --force --options runtime "$timestamp_flag" --sign "$identity" "$uv_target"
  fi
fi
