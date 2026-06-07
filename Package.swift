// swift-tools-version:6.1

import PackageDescription

let concurrencyChecking: [SwiftSetting] = [
  .unsafeFlags(["-strict-concurrency=complete"])
]

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
    .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.13.5"),
    .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "603.0.0"),
    .package(url: "https://github.com/tree-sitter/swift-tree-sitter", exact: "0.25.0"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-bash", exact: "0.25.1"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-html", exact: "0.23.2"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-json", exact: "0.24.8"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-python", exact: "0.25.0"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-typescript", exact: "0.23.2"),
  ],
  targets: [
    .target(
      name: "LocalCoderCore",
      dependencies: [
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "SwiftSoup", package: "SwiftSoup"),
        .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
        .product(name: "TreeSitterBash", package: "tree-sitter-bash"),
        .product(name: "TreeSitterHTML", package: "tree-sitter-html"),
        .product(name: "TreeSitterJSON", package: "tree-sitter-json"),
        .product(name: "TreeSitterPython", package: "tree-sitter-python"),
        .product(name: "TreeSitterTypeScript", package: "tree-sitter-typescript"),
        "TreeSitterPythonScanner",
      ],
      swiftSettings: concurrencyChecking
    ),
    .target(
      name: "TreeSitterPythonScanner",
      path: "Sources/TreeSitterPythonScanner",
      sources: ["scanner.c"],
      publicHeadersPath: "include",
      cSettings: [.headerSearchPath("include")]
    ),
    .target(
      name: "DataModelGeneratorCore",
      dependencies: [
        .product(name: "SwiftParser", package: "swift-syntax"),
        .product(name: "SwiftSyntax", package: "swift-syntax"),
      ],
      swiftSettings: concurrencyChecking
    ),
    .executableTarget(
      name: "DataModelGenerator",
      dependencies: ["DataModelGeneratorCore"],
      swiftSettings: concurrencyChecking
    ),
    .testTarget(
      name: "LocalCoderCoreTests",
      dependencies: ["LocalCoderCore"],
      resources: [.process("Fixtures")],
      swiftSettings: concurrencyChecking
    ),
    .testTarget(
      name: "DataModelGeneratorTests",
      dependencies: ["DataModelGeneratorCore"],
      swiftSettings: concurrencyChecking
    ),
  ]
)
