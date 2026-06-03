// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "LocalCoderCore",
  platforms: [
    .macOS(.v26)
  ],
  products: [
    .library(
      name: "LocalCoderCore",
      targets: ["LocalCoderCore"]
    )
  ],
  targets: [
    .target(
      name: "LocalCoderCore"
    ),
    .testTarget(
      name: "LocalCoderCoreTests",
      dependencies: ["LocalCoderCore"]
    ),
  ]
)
