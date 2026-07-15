#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-build/DerivedData}"
APP_PATH="${APP_PATH:-build/artifacts/export/Sumika.app}"
ASSET_PATH="${ASSET_PATH:-build/artifacts/Sumika-macos-release.dmg}"
DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-https://example.invalid/sumika/releases/}"
RELEASE_NOTES_PATH="${RELEASE_NOTES_PATH:-CHANGELOG.md}"
FEED_DIR="build/artifacts/sparkle-feed"
PAGES_DIR="build/artifacts/sparkle-pages"
PRODUCT_LINK="${PRODUCT_LINK:-https://sumika.chat}"
VERIFY_DOWNLOAD_URL="${VERIFY_DOWNLOAD_URL:-0}"

test -d "$APP_PATH"
test -f "$ASSET_PATH"
test -s "$RELEASE_NOTES_PATH"

EXPECTED_BUILD_VERSION="${EXPECTED_BUILD_VERSION:-$(/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleVersion' \
  "$APP_PATH/Contents/Info.plist")}"
EXPECTED_SHORT_VERSION="${EXPECTED_SHORT_VERSION:-$(/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleShortVersionString' \
  "$APP_PATH/Contents/Info.plist")}"

asset_name="$(basename "$ASSET_PATH")"
release_notes_name="${asset_name%.*}.md"
appcast_path="$FEED_DIR/appcast.xml"
generate_appcast="$DERIVED_DATA_PATH/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast"
sign_update="$DERIVED_DATA_PATH/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
expected_download_url="${DOWNLOAD_URL_PREFIX%/}/$asset_name"

test -x "$generate_appcast"
test -x "$sign_update"

run_with_sparkle_key() {
  local tool="$1"
  shift

  if [[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
    printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$tool" --ed-key-file - "$@"
  else
    "$tool" "$@"
  fi
}

rm -rf "$FEED_DIR" "$PAGES_DIR"
mkdir -p "$FEED_DIR" "$PAGES_DIR"
cp "$ASSET_PATH" "$FEED_DIR/$asset_name"
cp "$RELEASE_NOTES_PATH" "$FEED_DIR/$release_notes_name"

run_with_sparkle_key "$generate_appcast" \
  --download-url-prefix "${DOWNLOAD_URL_PREFIX%/}/" \
  --embed-release-notes \
  --maximum-versions 1 \
  --maximum-deltas 0 \
  --link "$PRODUCT_LINK" \
  -o "$appcast_path" \
  "$FEED_DIR"

test -s "$appcast_path"
xmllint --noout "$appcast_path"

item_count="$(xmllint --xpath 'count(/rss/channel/item)' "$appcast_path")"
feed_version="$(xmllint --xpath \
  'string(/rss/channel/item[1]/*[local-name()="version"])' \
  "$appcast_path")"
short_version="$(xmllint --xpath \
  'string(/rss/channel/item[1]/*[local-name()="shortVersionString"])' \
  "$appcast_path")"
minimum_system_version="$(xmllint --xpath \
  'string(/rss/channel/item[1]/*[local-name()="minimumSystemVersion"])' \
  "$appcast_path")"
enclosure_url="$(xmllint --xpath \
  'string(/rss/channel/item[1]/enclosure/@url)' \
  "$appcast_path")"
enclosure_length="$(xmllint --xpath \
  'string(/rss/channel/item[1]/enclosure/@length)' \
  "$appcast_path")"
enclosure_signature="$(xmllint --xpath \
  'string(/rss/channel/item[1]/enclosure/@*[local-name()="edSignature"])' \
  "$appcast_path")"
expected_length="$(stat -f '%z' "$ASSET_PATH")"
expected_minimum_system_version="$(/usr/libexec/PlistBuddy \
  -c 'Print :LSMinimumSystemVersion' \
  "$APP_PATH/Contents/Info.plist")"

test "$item_count" = "1"
test "$feed_version" = "$EXPECTED_BUILD_VERSION"
test "$short_version" = "$EXPECTED_SHORT_VERSION"
test "$minimum_system_version" = "$expected_minimum_system_version"
test "$enclosure_url" = "$expected_download_url"
test "$enclosure_length" = "$expected_length"
test -n "$enclosure_signature"

run_with_sparkle_key "$sign_update" \
  --verify \
  "$ASSET_PATH" \
  "$enclosure_signature"

tampered_asset="$(mktemp "${TMPDIR:-/tmp}/sumika-tampered-update.XXXXXX")"
trap 'rm -f "$tampered_asset"' EXIT
cp "$ASSET_PATH" "$tampered_asset"
printf '\0' >> "$tampered_asset"
if run_with_sparkle_key "$sign_update" \
  --verify \
  "$tampered_asset" \
  "$enclosure_signature" >/dev/null 2>&1; then
  echo "Tampered Sparkle update unexpectedly passed signature verification." >&2
  exit 1
fi

if [[ "$VERIFY_DOWNLOAD_URL" == "1" ]]; then
  curl \
    --fail \
    --head \
    --location \
    --retry 5 \
    --retry-all-errors \
    --retry-delay 2 \
    --show-error \
    --silent \
    --output /dev/null \
    "$expected_download_url"
elif [[ "$VERIFY_DOWNLOAD_URL" != "0" ]]; then
  echo "VERIFY_DOWNLOAD_URL must be either 0 or 1." >&2
  exit 1
fi

cp "$appcast_path" "$PAGES_DIR/appcast.xml"
echo "$PAGES_DIR/appcast.xml"
