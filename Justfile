project := "local-coder.xcodeproj"
scheme := "local-coder"
destination := "platform=macOS"
derived_data := "build/DerivedData"

default:
  @just --list

build:
    xcodebuild -project {{project}} -scheme {{scheme}} -destination "{{destination}}" -derivedDataPath {{derived_data}} build

test:
    xcodebuild -project {{project}} -scheme {{scheme}} -destination "{{destination}}" -derivedDataPath {{derived_data}} test

check-warnings:
    @log=$(mktemp); \
    status=0; \
    xcodebuild -quiet -project {{project}} -scheme {{scheme}} -destination "{{destination}}" -derivedDataPath {{derived_data}} clean build >"$log" 2>&1 || status=$?; \
    warnings=$(grep -E "/local-coder/(local-coder|local-coderTests)/.*: warning:" "$log" || true); \
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

format:
    @command -v swift-format >/dev/null || { echo "swift-format is not installed."; exit 127; }
    swift-format format --in-place --recursive --parallel local-coder local-coderTests
