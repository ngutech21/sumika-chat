import Foundation

public struct BrowserRefreshInput: Codable, Equatable, Sendable {
  public var hard: Bool?

  private enum CodingKeys: String, CodingKey {
    case hard
  }

  public init(hard: Bool? = nil) {
    self.hard = hard
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    hard = try Self.decodeOptionalBool(from: container, forKey: .hard)
  }

  private static func decodeOptionalBool(
    from container: KeyedDecodingContainer<CodingKeys>,
    forKey key: CodingKeys
  ) throws -> Bool? {
    guard container.contains(key) else {
      return nil
    }
    if let value = try? container.decode(Bool.self, forKey: key) {
      return value
    }
    if let rawValue = try? container.decode(String.self, forKey: key) {
      switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
      case "true":
        return true
      case "false":
        return false
      default:
        break
      }
    }
    throw BrowserToolInputValidationError.invalidBooleanArgument("hard")
  }
}

public enum BrowserToolInputValidationError: LocalizedError, Equatable {
  case invalidBooleanArgument(String)
  case invalidIntegerArgument(String)
  case invalidMaxLength
  case emptySelector

  public var errorDescription: String? {
    switch self {
    case .invalidBooleanArgument(let name):
      "browser tool argument \(name) must be true or false."
    case .invalidIntegerArgument(let name):
      "browser tool argument \(name) must be an integer."
    case .invalidMaxLength:
      "browser_inspect maxLength must be greater than or equal to 1."
    case .emptySelector:
      "browser_inspect selector must be omitted or non-empty."
    }
  }
}

public enum BrowserRefreshResult: Codable, Equatable, Sendable {
  case success(path: WorkspaceRelativePath?, url: String?, hard: Bool)
  case failed(reason: ToolFailureReason)
}

nonisolated extension BrowserRefreshResult {
  var preview: ToolResultPreview {
    switch self {
    case .success(let path, let url, let hard):
      let pathLine = path.map { "Preview path: \($0.rawValue)\n" } ?? ""
      let urlLine = url.map { "URL: \($0)\n" } ?? ""
      return ToolResultPreview(
        text: "\(pathLine)\(urlLine)Reloaded current preview.\nHard reload: \(hard)",
        affectedPaths: path.map { [$0.rawValue] } ?? []
      )
    case .failed(let reason):
      return ToolResultPreview(status: reason.previewStatus, text: reason.message)
    }
  }
}

nonisolated extension ToolDefinition {
  public static let browserRefresh = ToolDefinition(
    name: .browserRefresh,
    description: "Reload the current HTML preview page.",
    parameters: [
      ToolParameterDefinition(
        name: "hard",
        description: "When true, reload from the original preview file. Defaults to false.",
        isRequired: false,
        valueType: .boolean,
        defaultValue: .bool(false)
      )
    ],
    capabilities: [],
    riskLevel: .low
  )
}

extension BrowserRefreshInput {
  static func decodeToolArguments(_ arguments: ToolCallArguments) throws -> BrowserRefreshInput {
    do {
      return try ToolInputDecoder.decode(BrowserRefreshInput.self, from: arguments)
    } catch let error as BrowserToolInputValidationError {
      switch error {
      case .invalidBooleanArgument(let name):
        throw InvalidToolCallReason.invalidArgumentType(name: name, expected: "true or false")
      case .invalidIntegerArgument(let name):
        throw InvalidToolCallReason.invalidArgumentType(name: name, expected: "an integer")
      case .invalidMaxLength:
        throw InvalidToolCallReason.invalidPagination("maxLength")
      case .emptySelector:
        throw InvalidToolCallReason.invalidArgumentType(
          name: "selector",
          expected: "omit it or provide a non-empty CSS selector"
        )
      }
    }
  }
}

public struct BrowserRefreshToolExecutor: TypedToolExecutor {
  public static let codec = ToolCodec<BrowserRefreshInput>(
    definition: ToolDefinition.browserRefresh,
    decodeArguments: BrowserRefreshInput.decodeToolArguments,
    makePayload: ToolCallPayload.browserRefresh,
    extractInput: { payload in
      guard case .browserRefresh(let input) = payload else {
        throw ToolInputDecodingError.payloadMismatch(
          expected: ToolDefinition.browserRefresh.name.rawValue,
          actual: payload.toolName.rawValue
        )
      }
      return input
    }
  )

  public init() {}

  public func evaluatePermission(
    _ input: BrowserRefreshInput,
    context: ToolContext
  ) -> ToolPermissionEvaluation {
    _ = input
    _ = context
    return ToolPermissionEvaluation(
      decision: .allowed,
      reason: "Refreshing the active HTML preview is allowed.",
      riskLevel: .low
    )
  }

  public func run(_ input: BrowserRefreshInput, context: ToolContext) async -> ToolResultPayload {
    .browserRefresh(await context.browserToolService.refresh(input))
  }
}
