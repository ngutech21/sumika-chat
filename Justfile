project := "local-coder.xcodeproj"
scheme := "local-coder"
destination := "platform=macOS"
derived_data := "build/DerivedData"

build:
    xcodebuild -project {{project}} -scheme {{scheme}} -destination "{{destination}}" -derivedDataPath {{derived_data}} build

test:
    xcodebuild -project {{project}} -scheme {{scheme}} -destination "{{destination}}" -derivedDataPath {{derived_data}} test

lint:
    @command -v swiftlint >/dev/null || { echo "swiftlint is not installed. Install it with: brew install swiftlint"; exit 127; }
    swiftlint lint --no-cache --config .swiftlint.yml

format:
    @command -v swift-format >/dev/null || { echo "swift-format is not installed."; exit 127; }
    swift-format format --in-place --recursive --parallel local-coder local-coderTests
