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
    .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0")
  ],
  targets: [
    .target(
      name: "LocalCoderCore",
      dependencies: [
        .product(name: "Crypto", package: "swift-crypto")
      ]
    ),
    .testTarget(
      name: "LocalCoderCoreTests",
      dependencies: ["LocalCoderCore"]
    ),
  ]
)
