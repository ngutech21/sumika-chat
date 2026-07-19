// swift-tools-version:6.1

import PackageDescription

let concurrencyChecking: [SwiftSetting] = [
  .unsafeFlags(["-strict-concurrency=complete"])
]

let appConcurrencyChecking: [SwiftSetting] = [
  .unsafeFlags([
    "-strict-concurrency=complete",
    "-default-isolation", "MainActor",
    "-enable-upcoming-feature", "NonisolatedNonsendingByDefault",
  ])
]

let package = Package(
  name: "Sumika",
  platforms: [
    .macOS(.v15)
  ],
  products: [
    .library(name: "SumikaCore",targets: ["SumikaCore"] ),
    .library(name: "SumikaApp", targets: ["SumikaApp"]),
    .library(name: "SumikaRuntimeMLX", targets: ["SumikaRuntimeMLX"])
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
    .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
    .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.13.5"),
    .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "603.0.0"),
    .package(url: "https://github.com/tree-sitter/swift-tree-sitter", exact: "0.25.0"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-bash", exact: "0.25.1"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-css", exact: "0.25.0"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-html", exact: "0.23.2"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-json", exact: "0.24.8"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-python", exact: "0.25.0"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-typescript", exact: "0.23.2"),
    .package(url: "https://github.com/ml-explore/mlx-swift/",from: "0.31.6"),
    .package(url: "https://github.com/ml-explore/mlx-swift-lm",revision: "343cae3799054b2e138ebfb1ae8d7d0f6c6a4a5b"),
    .package(url: "https://github.com/huggingface/swift-transformers",from: "1.3.3"),
    .package(url: "https://github.com/huggingface/swift-huggingface",from: "0.9.0"),
    .package(url: "https://github.com/FluidInference/FluidAudio",from: "0.15.4"),
    .package(url: "https://github.com/migueldeicaza/SwiftTerm",from: "1.13.0"),
    .package(url: "https://github.com/swiftlang/swift-markdown.git",from: "0.8.0"),
    .package(url: "https://github.com/sparkle-project/Sparkle",from: "2.9.4"),

  ],
  targets: [
    .target(
      name: "SumikaCore",
      dependencies: [
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "MCP", package: "swift-sdk"),
        .product(name: "SwiftSoup", package: "SwiftSoup"),
        .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
        .product(name: "TreeSitterBash", package: "tree-sitter-bash"),
        .product(name: "TreeSitterCSS", package: "tree-sitter-css"),
        .product(name: "TreeSitterHTML", package: "tree-sitter-html"),
        .product(name: "TreeSitterJSON", package: "tree-sitter-json"),
        .product(name: "TreeSitterPython", package: "tree-sitter-python"),
        .product(name: "TreeSitterTypeScript", package: "tree-sitter-typescript"),
        "TreeSitterCSSScanner",
        "TreeSitterPythonScanner",
      ],
      swiftSettings: concurrencyChecking
    ),
    .target(
      name: "SumikaApp",
      dependencies: [
        "SumikaCore",
        "SumikaRuntimeMLX",
        .product(name: "MLX", package: "mlx-swift"), // fixme move to mlxruntime
        .product(name: "MLXLLM", package: "mlx-swift-lm"), // fixme move to mlxruntime
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"), // fixme move to mlxruntime
        .product(name: "MLXVLM", package: "mlx-swift-lm"), // fixme move to mlxruntime
        .product(name: "Tokenizers", package: "swift-transformers"), // fixme move to mlxruntime
        .product(name: "HuggingFace", package: "swift-huggingface"), // fixme move to mlxruntime
        .product(name: "FluidAudio", package: "FluidAudio"),
        .product(name: "SwiftTerm", package: "SwiftTerm"),
        .product(name: "Markdown", package: "swift-markdown"),
        .product(name: "Sparkle", package: "Sparkle"),
      ],
      swiftSettings: appConcurrencyChecking
    ),
    .target(
      name: "SumikaRuntimeMLX",
      dependencies: [
        "SumikaCore",
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "MLXLLM", package: "mlx-swift-lm"),
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        .product(name: "MLXVLM", package: "mlx-swift-lm"),
        .product(name: "Tokenizers", package: "swift-transformers"),
        .product(name: "HuggingFace", package: "swift-huggingface"),
      ],
      swiftSettings: concurrencyChecking
    ),
    .target(
      name: "TreeSitterCSSScanner",
      path: "Sources/TreeSitterCSSScanner",
      sources: ["scanner.c"],
      publicHeadersPath: "include",
      cSettings: [.headerSearchPath("include")]
    ),
    .target(
      name: "TreeSitterPythonScanner",
      path: "Sources/TreeSitterPythonScanner",
      sources: ["scanner.c"],
      publicHeadersPath: "include",
      cSettings: [.headerSearchPath("include")]
    ),
    .executableTarget(
      name: "DataModelGenerator",
      dependencies: [
        .product(name: "SwiftParser", package: "swift-syntax"),
        .product(name: "SwiftSyntax", package: "swift-syntax"),
      ],
      swiftSettings: concurrencyChecking
    ),
    .testTarget(
      name: "SumikaCoreTests",
      dependencies: [
        "SumikaCore",
        .product(name: "MCP", package: "swift-sdk"),
      ],
      resources: [.process("Fixtures")],
      swiftSettings: concurrencyChecking
    ),
    .testTarget(
      name: "DataModelGeneratorTests",
      dependencies: ["DataModelGenerator"],
      swiftSettings: concurrencyChecking
    ),
  ]
)
