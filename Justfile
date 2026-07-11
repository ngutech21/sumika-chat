project := "Sumika.xcodeproj"
scheme := "Sumika"
destination := "platform=macOS,arch=arm64"
derived_data := env("DERIVED_DATA_PATH", "build/DerivedData")
configuration := "Release"
app_name := "Sumika"
artifact_dir := "build/artifacts"

swift := env("SWIFT", "swift")


default:
  @just --list

# installs the dev tools on macos
deps:
   brew install swiftlint swift-format periphery create-dmg

resolve-packages:
    xcodebuild -resolvePackageDependencies -project {{project}} -scheme {{scheme}}

build:
    @set --; \
    if [ -n "${MARKETING_VERSION:-}" ]; then set -- "$@" "MARKETING_VERSION=$MARKETING_VERSION"; fi; \
    if [ -n "${CURRENT_PROJECT_VERSION:-}" ]; then set -- "$@" "CURRENT_PROJECT_VERSION=$CURRENT_PROJECT_VERSION"; fi; \
    if [ -n "${SUMIKA_RELEASE_VERSION:-}" ]; then set -- "$@" "SUMIKA_RELEASE_VERSION=$SUMIKA_RELEASE_VERSION"; fi; \
    xcodebuild -quiet -project {{project}} -scheme {{scheme}} -destination "{{destination}}" -derivedDataPath {{derived_data}} SUMIKA_GIT_COMMIT="$(git rev-parse HEAD 2>/dev/null || true)" "$@" build

release:
    @set --; \
    if [ -n "${MARKETING_VERSION:-}" ]; then set -- "$@" "MARKETING_VERSION=$MARKETING_VERSION"; fi; \
    if [ -n "${CURRENT_PROJECT_VERSION:-}" ]; then set -- "$@" "CURRENT_PROJECT_VERSION=$CURRENT_PROJECT_VERSION"; fi; \
    if [ -n "${SUMIKA_RELEASE_VERSION:-}" ]; then set -- "$@" "SUMIKA_RELEASE_VERSION=$SUMIKA_RELEASE_VERSION"; fi; \
    xcodebuild -quiet -project {{project}} -scheme {{scheme}} -destination "{{destination}}" -derivedDataPath {{derived_data}} -configuration {{configuration}} SUMIKA_GIT_COMMIT="$(git rev-parse HEAD 2>/dev/null || true)" "$@" build

release-unsigned:
    @set --; \
    if [ -n "${MARKETING_VERSION:-}" ]; then set -- "$@" "MARKETING_VERSION=$MARKETING_VERSION"; fi; \
    if [ -n "${CURRENT_PROJECT_VERSION:-}" ]; then set -- "$@" "CURRENT_PROJECT_VERSION=$CURRENT_PROJECT_VERSION"; fi; \
    if [ -n "${SUMIKA_RELEASE_VERSION:-}" ]; then set -- "$@" "SUMIKA_RELEASE_VERSION=$SUMIKA_RELEASE_VERSION"; fi; \
    xcodebuild -quiet -project {{project}} -scheme {{scheme}} -destination "{{destination}}" -derivedDataPath {{derived_data}} -configuration {{configuration}} SUMIKA_GIT_COMMIT="$(git rev-parse HEAD 2>/dev/null || true)" "$@" CODE_SIGNING_ALLOWED=NO build

release-signed:
    @if [ -z "${DEVELOPER_ID_APPLICATION:-}" ]; then echo "DEVELOPER_ID_APPLICATION is required, for example: Developer ID Application"; exit 1; fi
    @if ! security find-identity -v -p codesigning | grep -F "$DEVELOPER_ID_APPLICATION" >/dev/null; then echo "Required Developer ID Application codesigning identity was not found."; exit 1; fi
    @set --; \
    if [ -n "${MARKETING_VERSION:-}" ]; then set -- "$@" "MARKETING_VERSION=$MARKETING_VERSION"; fi; \
    if [ -n "${CURRENT_PROJECT_VERSION:-}" ]; then set -- "$@" "CURRENT_PROJECT_VERSION=$CURRENT_PROJECT_VERSION"; fi; \
    if [ -n "${SUMIKA_RELEASE_VERSION:-}" ]; then set -- "$@" "SUMIKA_RELEASE_VERSION=$SUMIKA_RELEASE_VERSION"; fi; \
    xcodebuild -quiet -project {{project}} -scheme {{scheme}} -destination "{{destination}}" -derivedDataPath {{derived_data}} -configuration {{configuration}} SUMIKA_GIT_COMMIT="$(git rev-parse HEAD 2>/dev/null || true)" "$@" CODE_SIGNING_ALLOWED=NO build
    @app_bundle="{{derived_data}}/Build/Products/{{configuration}}/{{app_name}}.app"; \
    test -d "$app_bundle"; \
    codesign --force --deep --options runtime --timestamp --entitlements sumika/Sumika.entitlements --sign "$DEVELOPER_ID_APPLICATION" "$app_bundle"; \
    codesign --verify --deep --strict --verbose=2 "$app_bundle"; \
    codesign --display --entitlements - "$app_bundle" | grep -F "com.apple.security.device.audio-input" >/dev/null || { echo "Signed app bundle is missing the audio-input entitlement."; exit 1; }

release-package artifact_name="Sumika-macos-release.dmg": release-signed
    @set -e; \
    app_bundle="{{derived_data}}/Build/Products/{{configuration}}/{{app_name}}.app"; \
    artifact_dir="{{artifact_dir}}"; \
    artifact="$artifact_dir/{{artifact_name}}"; \
    dmg_root="$artifact_dir/dmg-root"; \
    test -d "$app_bundle"; \
    mkdir -p "$artifact_dir"; \
    codesign --verify --deep --strict --verbose=2 "$app_bundle"; \
    rm -rf "$dmg_root"; \
    rm -f "$artifact"; \
    mkdir -p "$dmg_root"; \
    ditto "$app_bundle" "$dmg_root/{{app_name}}.app"; \
    create-dmg \
        --volname "{{app_name}}" \
        --window-size 640 360 \
        --icon-size 96 \
        --icon "{{app_name}}.app" 180 170 \
        --hide-extension "{{app_name}}.app" \
        --app-drop-link 460 170 \
        --format UDZO \
        "$artifact" \
        "$dmg_root"; \
    codesign --force --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$artifact"; \
    codesign --verify --strict --verbose=2 "$artifact"; \
    echo "$artifact"

release-notarize artifact_name="Sumika-macos-release.dmg":
    @set -e; \
    artifact="{{artifact_dir}}/{{artifact_name}}"; \
    test -f "$artifact"; \
    test -n "${APP_STORE_CONNECT_API_KEY_ID:-}" || { echo "APP_STORE_CONNECT_API_KEY_ID is required."; exit 1; }; \
    test -n "${APP_STORE_CONNECT_API_KEY_P8_BASE64:-}" || { echo "APP_STORE_CONNECT_API_KEY_P8_BASE64 is required."; exit 1; }; \
    key_path="$(mktemp "${TMPDIR:-/tmp}/sumika-notary-key.XXXXXX")"; \
    printf '%s' "$APP_STORE_CONNECT_API_KEY_P8_BASE64" | base64 --decode > "$key_path"; \
    trap 'rm -f "$key_path"' EXIT; \
    xcrun notarytool submit "$artifact" --key "$key_path" --key-id "$APP_STORE_CONNECT_API_KEY_ID" --wait; \
    xcrun stapler staple "$artifact"; \
    xcrun stapler validate "$artifact"; \
    codesign --verify --strict --verbose=2 "$artifact"; \
    echo "$artifact"

release-notarized artifact_name="Sumika-macos-release.dmg":
    just release-package "{{artifact_name}}"
    just release-notarize "{{artifact_name}}"

test: test-core test-app

test-core:
    {{swift}} test --no-parallel -q -Xswiftc -warnings-as-errors


data-model:
    mkdir -p .build/data-model-build .build/swiftpm-cache .build/clang-module-cache .build/swiftpm-home
    HOME="$PWD/.build/swiftpm-home" CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" {{swift}} run -q --disable-sandbox --build-path .build/data-model-build --cache-path .build/swiftpm-cache DataModelGenerator

test-app:
    @set --; \
    if [ -n "${CLONED_SOURCE_PACKAGES_DIR_PATH:-}" ]; then set -- "$@" -clonedSourcePackagesDirPath "$CLONED_SOURCE_PACKAGES_DIR_PATH"; fi; \
    xcodebuild -quiet -project {{project}} -scheme {{scheme}} -destination "{{destination}}" -derivedDataPath {{derived_data}} "$@" -parallel-testing-enabled NO clean test

test-app-tsan:
    @set --; \
    if [ -n "${CLONED_SOURCE_PACKAGES_DIR_PATH:-}" ]; then set -- "$@" -clonedSourcePackagesDirPath "$CLONED_SOURCE_PACKAGES_DIR_PATH"; fi; \
    xcodebuild -quiet -project {{project}} -scheme {{scheme}} -destination "{{destination}}" -derivedDataPath {{derived_data}}-tsan "$@" -enableThreadSanitizer YES -parallel-testing-enabled NO test

test-app-asan:
    @set --; \
    if [ -n "${CLONED_SOURCE_PACKAGES_DIR_PATH:-}" ]; then set -- "$@" -clonedSourcePackagesDirPath "$CLONED_SOURCE_PACKAGES_DIR_PATH"; fi; \
    xcodebuild -quiet -project {{project}} -scheme {{scheme}} -destination "{{destination}}" -derivedDataPath {{derived_data}}-asan "$@" -enableAddressSanitizer YES -parallel-testing-enabled NO test

test-ui:
    @echo "Gemma trace directory: $HOME/Library/Application Support/Sumika/debug/traces"; \
    status=0; \
    SUMIKA_DEBUG_TRACE=1 xcodebuild -quiet -project {{project}} -scheme SumikaUITests -destination "{{destination}}" -derivedDataPath {{derived_data}} -parallel-testing-enabled NO test -only-testing:SumikaUITests/SumikaUITests || status=$?; \
    result=$(ls -td {{derived_data}}/Logs/Test/Test-SumikaUITests-*.xcresult 2>/dev/null | head -n 1 || true); \
    if [ -n "$result" ]; then \
        skip_messages=$(xcrun xcresulttool get test-results tests --path "$result" 2>/dev/null | sed -n 's/^.*"name" : "Test skipped - \(.*\)",$/\1/p' | sort -u); \
        if [ -n "$skip_messages" ]; then \
            echo "UI tests skipped:"; \
            echo "$skip_messages" | sed 's/^/  - /'; \
        fi; \
    fi; \
    exit "$status"

perf-report scenario="ui-trace":
    @trace_path="$HOME/Library/Application Support/Sumika/debug/gemma-trace.jsonl"; trace_dir="$HOME/Library/Application Support/Sumika/debug/traces"; latest_trace=""; if [ -d "$trace_dir" ]; then latest_trace="$(ls -t "$trace_dir"/*-ui-test.jsonl 2>/dev/null | head -n 1 || true)"; if [ -n "$latest_trace" ]; then trace_path="$latest_trace"; fi; fi; if [ -z "$latest_trace" ] && [ -f .perf/ui-tests/latest-trace-path.txt ]; then candidate="$(cat .perf/ui-tests/latest-trace-path.txt)"; if [ -f "$candidate" ]; then trace_path="$candidate"; fi; fi; echo "Gemma trace: $trace_path"; xcrun swift script/trace_performance_report.swift "$trace_path" --model-id gemma4-e4b --scenario "{{scenario}}" --limit all

signpost-report scenario="manual-chat" last="20m":
    mkdir -p .build/swift-script-module-cache
    xcrun swift -module-cache-path .build/swift-script-module-cache script/chat_signpost_report.swift --last "{{last}}" --scenario "{{scenario}}"

coverage:
    xcodebuild -quiet -project {{project}} -scheme {{scheme}} -destination "{{destination}}" -derivedDataPath {{derived_data}} -enableCodeCoverage YES test
    @result=$(ls -td {{derived_data}}/Logs/Test/*.xcresult 2>/dev/null | head -n 1); \
    if [ -z "$result" ]; then \
        echo "No test result bundle found."; \
        exit 1; \
    fi; \
    xcrun xccov view --report "$result"

coverage-low threshold="80":
    @log=$(mktemp); \
    xcodebuild -quiet -project {{project}} -scheme {{scheme}} -destination "{{destination}}" -derivedDataPath {{derived_data}} -enableCodeCoverage YES test >"$log" 2>&1 || { cat "$log"; rm -f "$log"; exit 1; }; \
    rm -f "$log"
    @threshold="{{threshold}}"; \
    threshold="${threshold#threshold=}"; \
    result=$(ls -td {{derived_data}}/Logs/Test/*.xcresult 2>/dev/null | head -n 1); \
    if [ -z "$result" ]; then \
        echo "No test result bundle found."; \
        exit 1; \
    fi; \
    json=$(mktemp); \
    xcrun xccov view --report --json "$result" >"$json" || { rm -f "$json"; exit 1; }; \
    xcrun swift script/coverage_low.swift "$json" --threshold "$threshold"; \
    rm -f "$json"

lint:
    @command -v swiftlint >/dev/null || { echo "swiftlint is not installed. Install it with: brew install swiftlint"; exit 127; }
    @configs="$(find . \( -path ./.git -o -path ./.build -o -path ./build -o -path ./DerivedData \) -prune -o -name .swiftlint.yml -print | sort | sed 's#^\./##')"; \
    if [ -z "$configs" ]; then \
        echo "No SwiftLint configuration files found."; \
        exit 1; \
    fi; \
    status=0; \
    for config in $configs; do \
        dir="$(dirname "$config")"; \
        echo "SwiftLint $config"; \
        if [ "$dir" = "." ]; then \
            swiftlint lint --quiet --strict --no-cache --config "$config" || status=$?; \
        else \
            swiftlint lint --quiet --strict --no-cache --config "$config" "$dir" || status=$?; \
        fi; \
    done; \
    exit "$status"

lint-analyze:
    @command -v swiftlint >/dev/null || { echo "swiftlint is not installed. Install it with: brew install swiftlint"; exit 127; }
    @log=$(mktemp); \
    trap 'rm -f "$log"' EXIT; \
    set --; \
    if [ -n "${CLONED_SOURCE_PACKAGES_DIR_PATH:-}" ]; then \
        set -- "$@" -clonedSourcePackagesDirPath "$CLONED_SOURCE_PACKAGES_DIR_PATH"; \
    fi; \
    status=0; \
    xcodebuild -project {{project}} -scheme {{scheme}} -destination "{{destination}}" -derivedDataPath {{derived_data}} "$@" CODE_SIGNING_ALLOWED=NO clean build >"$log" 2>&1 || status=$?; \
    if [ "$status" -ne 0 ]; then \
        cat "$log"; \
        exit "$status"; \
    fi; \
    swiftlint analyze --quiet --strict --config .swiftlint-analyze.yml --compiler-log-path "$log"

final-check: typos format lint periphery test

format:
    @command -v swift-format >/dev/null || { echo "swift-format is not installed."; exit 127; }
    swift-format lint --strict --recursive --parallel sumika SumikaTests SumikaUITests Sources Tests Package.swift

format-fix:
    @command -v swift-format >/dev/null || { echo "swift-format is not installed."; exit 127; }
    swift-format format --in-place --recursive --parallel sumika SumikaTests SumikaUITests Sources Tests Package.swift

typos:
    typos -q --format brief

periphery:
    periphery scan --retain-public --retain-codable-properties --baseline .periphery-core-baseline --relative-results --disable-update-check
    @set -- -destination platform=macOS; \
    if [ -n "${CLONED_SOURCE_PACKAGES_DIR_PATH:-}" ]; then set -- "$@" -clonedSourcePackagesDirPath "$CLONED_SOURCE_PACKAGES_DIR_PATH"; fi; \
    periphery scan --project Sumika.xcodeproj --schemes Sumika --retain-public --retain-codable-properties --report-include "sumika/**/*.swift" --baseline .periphery-app-baseline --relative-results --disable-update-check -- "$@"
