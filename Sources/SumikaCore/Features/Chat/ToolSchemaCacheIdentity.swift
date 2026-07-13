// Crypto is used directly; the analyzer compiler log does not attribute it reliably.
// swiftlint:disable:next unused_import
import Crypto
import Foundation

enum ToolSchemaCacheIdentity {
  private struct ModelToolSchema: Encodable {
    let functionSchema: FunctionToolSchema
    let rawParametersSchema: ToolArgumentValue?
  }

  static func instructions(
    stableInstructions: String,
    registry: ToolRegistry
  ) throws -> String {
    guard !registry.tools.isEmpty else {
      return stableInstructions
    }

    let schemas = registry.tools.map { definition in
      ModelToolSchema(
        functionSchema: definition.functionSchema,
        rawParametersSchema: definition.rawParametersSchema
      )
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let schemaData = try encoder.encode(schemas)
    let digest = SHA256.hash(data: schemaData)
      .map { String(format: "%02x", $0) }
      .joined()
    return stableInstructions + "\n\n[tool-schema-sha256:\(digest)]"
  }
}
