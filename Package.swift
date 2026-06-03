// swift-tools-version: 6.1

import PackageDescription

let package = Package(
  name: "LocalCoderCore",
  platforms: [
    .macOS(.v15)
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
