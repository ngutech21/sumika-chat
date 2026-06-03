project := "local-coder.xcodeproj"
scheme := "local-coder"
destination := "platform=macOS,arch=arm64"
derived_data := "build/DerivedData"

default:
  @just --list

build:
    xcodebuild -project {{project}} -scheme {{scheme}} -destination "{{destination}}" -derivedDataPath {{derived_data}} build

release:
    xcodebuild -project {{project}} -scheme {{scheme}} -destination "{{destination}}" -derivedDataPath {{derived_data}} -configuration Release build

test: test-core test-app

test-core:
    /usr/bin/time -p xcrun swift test

test-app:
    xcodebuild -project {{project}} -scheme {{scheme}} -destination "{{destination}}" -derivedDataPath {{derived_data}} clean test

coverage:
    xcodebuild -project {{project}} -scheme {{scheme}} -destination "{{destination}}" -derivedDataPath {{derived_data}} -enableCodeCoverage YES test
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
    warnings=$(grep -E "/local-coder/(local-coder|local-coderTests|Sources|Tests)/.*: warning:" "$log" || true); \
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
    swiftlint lint --no-cache --config .swiftlint.yml

final-check: format lint test check-warnings

format:
    @command -v swift-format >/dev/null || { echo "swift-format is not installed."; exit 127; }
    swift-format format --in-place --recursive --parallel local-coder local-coderTests Sources Tests Package.swift
