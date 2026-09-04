// swift-tools-version:6.1

import PackageDescription

let package = Package(
  name: "SumikaSwiftLint",
  platforms: [
    .macOS(.v15)
  ],
  dependencies: [
    .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", exact: "0.65.1")
  ]
)
