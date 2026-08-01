#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Sumika"
PROJECT_NAME="Sumika.xcodeproj"
SCHEME_NAME="Sumika"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_DIR="$ROOT_DIR/build/DerivedData"
APP_BUNDLE="$DERIVED_DATA_DIR/Build/Products/Debug/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
TRACE_DIR="$HOME/Library/Application Support/Sumika/debug/traces"
GIT_COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || true)"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
pkill -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" >/dev/null 2>&1 || true

xcodebuild \
  -project "$ROOT_DIR/$PROJECT_NAME" \
  -scheme "$SCHEME_NAME" \
  -destination "platform=macOS,arch=arm64" \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  SUMIKA_GIT_COMMIT="$GIT_COMMIT" \
  build

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
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
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"chat.sumika\""
    ;;
  --trace|trace)
    trace_basename="$(date -u +%Y-%m-%dT%H%M%SZ)-$(uuidgen)-mlx-trace.jsonl"
    trace_file="$TRACE_DIR/$trace_basename"
    echo "MLX trace: $trace_file"
    SUMIKA_DEBUG_TRACE=1 SUMIKA_DEBUG_TRACE_BASENAME="$trace_basename" "$APP_BINARY"
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
