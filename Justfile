set quiet := true

project := "Sumika.xcodeproj"
scheme := "Sumika"
destination := "platform=macOS,arch=arm64"
derived_data := "build/DerivedData"

swift := env("SWIFT", "swift")


default:
  @just --list

build:
    xcodebuild -quiet -project {{project}} -scheme {{scheme}} -destination "{{destination}}" -derivedDataPath {{derived_data}} build

release:
    xcodebuild -quiet -project {{project}} -scheme {{scheme}} -destination "{{destination}}" -derivedDataPath {{derived_data}} -configuration Release build

test: test-core test-app

test-core:
    {{swift}} test --no-parallel -q -Xswiftc -warnings-as-errors


data-model:
    mkdir -p .build/data-model-build .build/swiftpm-cache .build/clang-module-cache .build/swiftpm-home
    HOME="$PWD/.build/swiftpm-home" CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" {{swift}} run -q --disable-sandbox --build-path .build/data-model-build --cache-path .build/swiftpm-cache DataModelGenerator

test-app:
    xcodebuild -quiet -project {{project}} -scheme {{scheme}} -destination "{{destination}}" -derivedDataPath {{derived_data}} clean test

test-ui:
    @echo "Gemma trace directory: $HOME/Library/Application Support/sumika-chat/debug/traces"; \
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
    @trace_path="$HOME/Library/Application Support/sumika-chat/debug/gemma-trace.jsonl"; trace_dir="$HOME/Library/Application Support/sumika-chat/debug/traces"; latest_trace=""; if [ -d "$trace_dir" ]; then latest_trace="$(ls -t "$trace_dir"/*-ui-test.jsonl 2>/dev/null | head -n 1 || true)"; if [ -n "$latest_trace" ]; then trace_path="$latest_trace"; fi; fi; if [ -z "$latest_trace" ] && [ -f .perf/ui-tests/latest-trace-path.txt ]; then candidate="$(cat .perf/ui-tests/latest-trace-path.txt)"; if [ -f "$candidate" ]; then trace_path="$candidate"; fi; fi; echo "Gemma trace: $trace_path"; xcrun swift script/trace_performance_report.swift "$trace_path" --model-id gemma4-e4b --scenario "{{scenario}}" --limit all

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

check-warnings:
    @log=$(mktemp); \
    status=0; \
    xcodebuild -quiet -project {{project}} -scheme {{scheme}} -destination "{{destination}}" -derivedDataPath {{derived_data}} clean build >"$log" 2>&1 || status=$?; \
    warnings=$(grep -E "/sumika-chat/(sumika|SumikaTests|Sources|Tests)/.*: warning:" "$log" || true); \
    if [ -n "$warnings" ]; then \
        echo "Local source warnings found:"; \
        echo "$warnings"; \
        rm -f "$log"; \
        exit 1; \
    fi; \
    if [ "$status" -ne 0 ]; then \
        cat "$log"; \
        rm -f "$log"; \
        exit "$status"; \
    fi; \
    rm -f "$log"; \
    echo "No local source warnings found."

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

final-check: typos format lint periphery test check-warnings

format:
    @command -v swift-format >/dev/null || { echo "swift-format is not installed."; exit 127; }
    swift-format format --in-place --recursive --parallel sumika SumikaTests SumikaUITests Sources Tests Package.swift

typos:
    typos -q --format brief

periphery:
    periphery scan --retain-public --retain-codable-properties --baseline .periphery-core-baseline --relative-results --disable-update-check
    periphery scan --project Sumika.xcodeproj --schemes Sumika --retain-public --retain-codable-properties --report-include "sumika/**/*.swift" --baseline .periphery-app-baseline --relative-results --disable-update-check -- -destination platform=macOS
