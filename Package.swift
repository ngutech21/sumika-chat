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
  dependencies: [
    .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
    .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "603.0.0"),
  ],
  targets: [
    .target(
      name: "LocalCoderCore",
      dependencies: [
        .product(name: "Crypto", package: "swift-crypto")
      ]
    ),
    .target(
      name: "DataModelGeneratorCore",
      dependencies: [
        .product(name: "SwiftParser", package: "swift-syntax"),
        .product(name: "SwiftSyntax", package: "swift-syntax"),
      ]
    ),
    .executableTarget(
      name: "DataModelGenerator",
      dependencies: ["DataModelGeneratorCore"]
    ),
    .testTarget(
      name: "LocalCoderCoreTests",
      dependencies: ["LocalCoderCore"]
    ),
    .testTarget(
      name: "DataModelGeneratorTests",
      dependencies: ["DataModelGeneratorCore"]
    ),
  ]
)
