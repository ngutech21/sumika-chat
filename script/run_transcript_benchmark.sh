#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
OUTPUT_DIR="$ROOT_DIR/.perf/transcript"
PARTS_DIR="$OUTPUT_DIR/$RUN_ID-parts"
XCRESULT_DIR="$ROOT_DIR/.perf/xcresults/$RUN_ID-transcript-benchmark"
SIGNPOST_DIR="$ROOT_DIR/.perf/signposts/$RUN_ID-transcript-benchmark"
DERIVED_DATA_DIR="${DERIVED_DATA_PATH:-$ROOT_DIR/build/DerivedData-transcript-benchmark}"
SOURCE_PACKAGES_DIR="${CLONED_SOURCE_PACKAGES_PATH:-$ROOT_DIR/build/DerivedData/SourcePackages}"
JSON_PATH="$OUTPUT_DIR/$RUN_ID-baseline.json"
MARKDOWN_PATH="$OUTPUT_DIR/$RUN_ID-baseline.md"

CASE_IDS=(
  history-10-tail-10000-paragraph
  history-100-tail-10000-paragraph
  history-500-tail-10000-paragraph
  history-1000-tail-10000-paragraph
  tail-500-1000-paragraph
  tail-500-10000-paragraph
  tail-500-50000-paragraph
  tail-500-1000-openCodeFence
  tail-500-10000-openCodeFence
  tail-500-50000-openCodeFence
  worst-1000-tail-50000-paragraph
  tool-heavy-500-tail-10000
  mixed-500-tail-10000
  attachment-history-500-text-tail-10000
  resize-1000-760-360-760
)

mkdir -p "$OUTPUT_DIR" "$PARTS_DIR" "$XCRESULT_DIR" "$SIGNPOST_DIR" \
  "$ROOT_DIR/.build/swift-script-module-cache"

fingerprint_paths() {
  while IFS= read -r -d '' source_path; do
    printf '%s\0' "$source_path"
    git hash-object "$source_path"
  done < <(git ls-files -z --cached --others --exclude-standard -- "$@")
}

export SUMIKA_RUN_TRANSCRIPT_BENCHMARK=1
export SUMIKA_TRANSCRIPT_BENCHMARK_OUTPUT="$JSON_PATH"
export SUMIKA_TRANSCRIPT_BENCHMARK_SAMPLES="${SUMIKA_TRANSCRIPT_BENCHMARK_SAMPLES:-100}"
export SUMIKA_TRANSCRIPT_BENCHMARK_WARMUPS="${SUMIKA_TRANSCRIPT_BENCHMARK_WARMUPS:-5}"
export SUMIKA_BENCHMARK_TIMESTAMP="$TIMESTAMP"
export SUMIKA_BENCHMARK_GIT_COMMIT="$(git rev-parse HEAD)"
export SUMIKA_BENCHMARK_GIT_BRANCH="$(git branch --show-current)"
export SUMIKA_BENCHMARK_SOURCE_FINGERPRINT="$({
  fingerprint_paths \
    Justfile Package.swift Package.resolved Sources sumika SumikaTests script Sumika.xcodeproj
} | shasum -a 256 | awk '{print $1}')"
export SUMIKA_BENCHMARK_PROTOCOL_FINGERPRINT="$({
  fingerprint_paths \
    SumikaTests/TranscriptPerformanceBenchmarkHarness.swift \
    SumikaTests/TranscriptPerformanceBenchmarkSupport.swift \
    SumikaTests/TranscriptPerformanceBenchmarkTests.swift \
    script/run_transcript_benchmark.sh \
    script/transcript_benchmark_merge.swift \
    script/transcript_benchmark_report.swift \
    Sumika.xcodeproj/project.pbxproj
} | shasum -a 256 | awk '{print $1}')"
if [ -n "$(git status --porcelain)" ]; then
  export SUMIKA_BENCHMARK_GIT_DIRTY=1
else
  export SUMIKA_BENCHMARK_GIT_DIRTY=0
fi
export SUMIKA_BENCHMARK_CONFIGURATION="Release"
export SUMIKA_BENCHMARK_OPTIMIZATION="app: whole-module -O; test harness: -Onone; ENABLE_TESTABILITY=YES"
export SUMIKA_BENCHMARK_COMPILE_CONDITION="SUMIKA_PERFORMANCE_DIAGNOSTICS"
export SUMIKA_BENCHMARK_ENABLE_TESTABILITY=1
export SUMIKA_BENCHMARK_TEST_HOST_DIAGNOSTICS="debug trace, Main Thread Checker, and Xcode performance diagnostics disabled; XCTest injection retained"
export SUMIKA_BENCHMARK_PROCESS_ISOLATION="one fresh xctest host process per scenario"
export SUMIKA_BENCHMARK_MAC_MODEL="$(/usr/sbin/sysctl -n hw.model 2>/dev/null || echo unknown)"
export SUMIKA_BENCHMARK_CHIP="$(/usr/sbin/sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"
export SUMIKA_BENCHMARK_MEMORY_BYTES="$(/usr/sbin/sysctl -n hw.memsize 2>/dev/null || echo 0)"
export SUMIKA_BENCHMARK_PROCESSOR_COUNT="$(/usr/sbin/sysctl -n hw.ncpu 2>/dev/null || echo 0)"
export SUMIKA_BENCHMARK_OS_VERSION="$(sw_vers -productVersion)"
export SUMIKA_BENCHMARK_OS_BUILD="$(sw_vers -buildVersion)"
export SUMIKA_BENCHMARK_XCODE_VERSION="$(xcodebuild -version | tr '\n' ' ')"
export SUMIKA_BENCHMARK_SWIFT_VERSION="$(xcrun swift --version | head -n 1)"

COMMON_ARGS=(
  -quiet
  -project Sumika.xcodeproj
  -scheme Sumika
  -configuration Release
  -destination "platform=macOS,arch=arm64"
  -derivedDataPath "$DERIVED_DATA_DIR"
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES_DIR"
  -disableAutomaticPackageResolution
  -parallel-testing-enabled NO
  -maximum-parallel-testing-workers 1
  -enableCodeCoverage NO
  ENABLE_TESTABILITY=YES
  'OTHER_SWIFT_FLAGS=$(inherited) -D SUMIKA_PERFORMANCE_DIAGNOSTICS'
)

xcodebuild "${COMMON_ARGS[@]}" build-for-testing

XCTESTRUN_PATH="$(find "$DERIVED_DATA_DIR/Build/Products" -maxdepth 1 -name '*.xctestrun' -print -quit)"
test -n "$XCTESTRUN_PATH"
TARGET_PATH="TestConfigurations.0.TestTargets.0"

for key_path in \
  "$TARGET_PATH.EnvironmentVariables.DYLD_INSERT_LIBRARIES" \
  "$TARGET_PATH.EnvironmentVariables.OS_ACTIVITY_DT_MODE" \
  "$TARGET_PATH.EnvironmentVariables.PERFC_ENABLE_EXTENDED_DIAGNOSTIC_FORMAT" \
  "$TARGET_PATH.EnvironmentVariables.PERFC_ENABLE_PROFILE_MODE" \
  "$TARGET_PATH.EnvironmentVariables.PERFC_RESET_INSERT_LIBRARIES" \
  "$TARGET_PATH.EnvironmentVariables.PERFC_SUPPRESS_SYSTEM_REPORTS" \
  "$TARGET_PATH.EnvironmentVariables.SQLITE_ENABLE_THREAD_ASSERTIONS" \
  "$TARGET_PATH.EnvironmentVariables.SUMIKA_DEBUG_TRACE" \
  "$TARGET_PATH.TestingEnvironmentVariables.PERFC_SUPPRESS_SYSTEM_REPORTS"
do
  plutil -remove "$key_path" "$XCTESTRUN_PATH" 2>/dev/null || true
done
plutil -replace "$TARGET_PATH.DiagnosticCollectionPolicy" -integer 0 "$XCTESTRUN_PATH"
plutil -replace "$TARGET_PATH.TestingEnvironmentVariables.DYLD_INSERT_LIBRARIES" \
  -string '__TESTHOST__/Contents/Frameworks/libXCTestBundleInject.dylib' \
  "$XCTESTRUN_PATH"

set_xctestrun_environment() {
  local variable_name key_path
  for variable_name in "$@"; do
    key_path="$TARGET_PATH.EnvironmentVariables.$variable_name"
    if ! plutil -replace "$key_path" -string "${!variable_name}" "$XCTESTRUN_PATH" 2>/dev/null; then
      plutil -insert "$key_path" -string "${!variable_name}" "$XCTESTRUN_PATH"
    fi
  done
}

ENVIRONMENT_VARIABLES=(
  SUMIKA_RUN_TRANSCRIPT_BENCHMARK
  SUMIKA_TRANSCRIPT_BENCHMARK_OUTPUT
  SUMIKA_TRANSCRIPT_BENCHMARK_SAMPLES
  SUMIKA_TRANSCRIPT_BENCHMARK_WARMUPS
  SUMIKA_TRANSCRIPT_BENCHMARK_CASE
  SUMIKA_BENCHMARK_TIMESTAMP
  SUMIKA_BENCHMARK_GIT_COMMIT
  SUMIKA_BENCHMARK_GIT_BRANCH
  SUMIKA_BENCHMARK_SOURCE_FINGERPRINT
  SUMIKA_BENCHMARK_PROTOCOL_FINGERPRINT
  SUMIKA_BENCHMARK_GIT_DIRTY
  SUMIKA_BENCHMARK_CONFIGURATION
  SUMIKA_BENCHMARK_OPTIMIZATION
  SUMIKA_BENCHMARK_COMPILE_CONDITION
  SUMIKA_BENCHMARK_ENABLE_TESTABILITY
  SUMIKA_BENCHMARK_TEST_HOST_DIAGNOSTICS
  SUMIKA_BENCHMARK_PROCESS_ISOLATION
  SUMIKA_BENCHMARK_MAC_MODEL
  SUMIKA_BENCHMARK_CHIP
  SUMIKA_BENCHMARK_MEMORY_BYTES
  SUMIKA_BENCHMARK_PROCESSOR_COUNT
  SUMIKA_BENCHMARK_OS_VERSION
  SUMIKA_BENCHMARK_OS_BUILD
  SUMIKA_BENCHMARK_XCODE_VERSION
  SUMIKA_BENCHMARK_SWIFT_VERSION
)

PART_PATHS=()
CASE_LOG_STARTS=()
CASE_LOG_ENDS=()
for case_id in "${CASE_IDS[@]}"; do
  export SUMIKA_TRANSCRIPT_BENCHMARK_CASE="$case_id"
  export SUMIKA_TRANSCRIPT_BENCHMARK_OUTPUT="$PARTS_DIR/$case_id.json"
  PART_PATHS+=("$SUMIKA_TRANSCRIPT_BENCHMARK_OUTPUT")
  set_xctestrun_environment "${ENVIRONMENT_VARIABLES[@]}"

  case_log_start="$(date '+%Y-%m-%d %H:%M:%S')"
  CASE_LOG_STARTS+=("$case_log_start")
  xcodebuild -quiet \
    -xctestrun "$XCTESTRUN_PATH" \
    -destination "platform=macOS,arch=arm64" \
    -parallel-testing-enabled NO \
    -maximum-parallel-testing-workers 1 \
    -resultBundlePath "$XCRESULT_DIR/$case_id.xcresult" \
    -only-testing:SumikaTests/TranscriptPerformanceBenchmarkTests \
    test-without-building
  case_log_end="$(date '+%Y-%m-%d %H:%M:%S')"
  CASE_LOG_ENDS+=("$case_log_end")
  test -s "$SUMIKA_TRANSCRIPT_BENCHMARK_OUTPUT"
done

xcrun swift \
  -module-cache-path "$ROOT_DIR/.build/swift-script-module-cache" \
  "$ROOT_DIR/script/transcript_benchmark_merge.swift" \
  "$JSON_PATH" \
  "${PART_PATHS[@]}"
xcrun swift \
  -module-cache-path "$ROOT_DIR/.build/swift-script-module-cache" \
  "$ROOT_DIR/script/transcript_benchmark_report.swift" \
  "$JSON_PATH" \
  "$MARKDOWN_PATH"

cp "$JSON_PATH" "$OUTPUT_DIR/latest.json"
cp "$MARKDOWN_PATH" "$OUTPUT_DIR/latest.md"

if [ "${SUMIKA_TRANSCRIPT_BENCHMARK_CAPTURE_SIGNPOSTS:-1}" = "1" ]; then
  predicate='subsystem == "chat.sumika" && category == "ChatTranscript" && process == "Sumika"'
  for index in "${!CASE_IDS[@]}"; do
    case_id="${CASE_IDS[$index]}"
    raw_signpost_path="$SIGNPOST_DIR/$case_id-raw.json"
    if /usr/bin/log show \
      --start "${CASE_LOG_STARTS[$index]}" \
      --end "${CASE_LOG_ENDS[$index]}" \
      --info \
      --signpost \
      --style json \
      --predicate "$predicate" > "$raw_signpost_path"
    then
      xcrun swift \
        -module-cache-path "$ROOT_DIR/.build/swift-script-module-cache" \
        "$ROOT_DIR/script/chat_signpost_report.swift" \
        --input "$raw_signpost_path" \
        --output-dir "$SIGNPOST_DIR" \
        --predicate "$predicate" \
        --scenario "$case_id" \
        --threshold-ms 16.7
      gzip -f "$raw_signpost_path"
    else
      echo "Warning: signposts for $case_id could not be captured." >&2
    fi
  done
fi

echo "Transcript benchmark JSON: $JSON_PATH"
echo "Transcript benchmark Markdown: $MARKDOWN_PATH"
echo "Transcript benchmark XCResults: $XCRESULT_DIR"
echo "Transcript benchmark signposts: $SIGNPOST_DIR"
