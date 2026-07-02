import Foundation

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
