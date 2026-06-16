#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="local-coder"
PROJECT_NAME="local-coder.xcodeproj"
SCHEME_NAME="local-coder"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_DIR="$ROOT_DIR/build/DerivedData"
APP_BUNDLE="$DERIVED_DATA_DIR/Build/Products/Debug/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
TRACE_FILE="$HOME/Library/Application Support/local-coder/debug/gemma-trace.jsonl"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
pkill -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" >/dev/null 2>&1 || true

xcodebuild \
  -project "$ROOT_DIR/$PROJECT_NAME" \
  -scheme "$SCHEME_NAME" \
  -destination "platform=macOS,arch=arm64" \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  build

open_app() {
  /usr/bin/open -n -a "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"ngutech21.local-coder\""
    ;;
  --trace|trace)
    echo "Gemma trace: $TRACE_FILE"
    LOCAL_CODER_DEBUG_TRACE=1 "$APP_BINARY"
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--trace|--verify]" >&2
    exit 2
    ;;
esac
