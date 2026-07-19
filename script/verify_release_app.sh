#!/bin/bash

set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "Usage: $0 <Sumika.app> [expected-team-identifier]" >&2
  exit 64
fi

app_bundle="$1"
expected_team="${2:-}"
info_plist="$app_bundle/Contents/Info.plist"
sparkle_framework="$app_bundle/Contents/Frameworks/Sparkle.framework"
sparkle_current="$sparkle_framework/Versions/Current"

test -d "$app_bundle" || {
  echo "Release app bundle not found: $app_bundle" >&2
  exit 1
}
test -f "$info_plist" || {
  echo "Release app is missing Contents/Info.plist." >&2
  exit 1
}
test -d "$sparkle_framework" || {
  echo "Release app is missing Sparkle.framework." >&2
  exit 1
}
test -L "$sparkle_framework/Versions/Current" || {
  echo "Sparkle.framework is missing its Versions/Current symlink." >&2
  exit 1
}

required_sparkle_code=(
  "$sparkle_framework"
  "$sparkle_current/Autoupdate"
  "$sparkle_current/Updater.app"
  "$sparkle_current/XPCServices/Downloader.xpc"
  "$sparkle_current/XPCServices/Installer.xpc"
)

required_sparkle_resources=(
  "$sparkle_current/Resources/Info.plist"
  "$sparkle_current/Resources/SUStatus.nib"
  "$sparkle_current/Resources/SUUpdateAlert.nib"
  "$sparkle_current/Updater.app/Contents/Info.plist"
)

for resource in "${required_sparkle_resources[@]}"; do
  test -e "$resource" || {
    echo "Sparkle release resource is missing: $resource" >&2
    exit 1
  }
done

for code in "${required_sparkle_code[@]}"; do
  test -e "$code" || {
    echo "Sparkle release code is missing: $code" >&2
    exit 1
  }
  codesign --verify --strict --verbose=2 "$code"

  if [ -n "$expected_team" ]; then
    signature_info="$(codesign --display --verbose=4 "$code" 2>&1)"
    printf '%s\n' "$signature_info" | grep -F "TeamIdentifier=$expected_team" >/dev/null || {
      echo "Sparkle release code has the wrong signing team: $code" >&2
      exit 1
    }
  fi
done

codesign --verify --deep --strict --verbose=2 "$app_bundle"

if ! otool -L "$app_bundle"/Contents/MacOS/* 2>/dev/null \
  | grep -F "Sparkle.framework" >/dev/null
then
  echo "Release executable does not link Sparkle.framework." >&2
  exit 1
fi

feed_url="$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$info_plist")"
public_key="$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$info_plist")"
test -n "$feed_url" || {
  echo "Release app has an empty SUFeedURL." >&2
  exit 1
}
test -n "$public_key" || {
  echo "Release app has an empty SUPublicEDKey." >&2
  exit 1
}

echo "Verified Sparkle in release app: $app_bundle"
