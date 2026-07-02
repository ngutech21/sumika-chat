import Foundation

extension BrowserInspectInput {
  static func decodeToolArguments(_ arguments: ToolCallArguments) throws -> BrowserInspectInput {
    do {
      return try ToolInputDecoder.decode(BrowserInspectInput.self, from: arguments)
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

public struct BrowserInspectToolExecutor: TypedToolExecutor {
  public static let codec = ToolCodec<BrowserInspectInput>(
    definition: ToolDefinition.browserInspect,
    decodeArguments: BrowserInspectInput.decodeToolArguments,
    makePayload: ToolCallPayload.browserInspect,
    extractInput: { payload in
      guard case .browserInspect(let input) = payload else {
        throw ToolInputDecodingError.payloadMismatch(
          expected: ToolDefinition.browserInspect.name.rawValue,
          actual: payload.toolName.rawValue
        )
      }
      return input
    }
  )

  public init() {}

  public func evaluatePermission(
    _ input: BrowserInspectInput,
    context: ToolContext
  ) -> ToolPermissionEvaluation {
    _ = input
    _ = context
    return ToolPermissionEvaluation(
      decision: .allowed,
      reason: "Inspecting the active HTML preview is allowed.",
      riskLevel: .low
    )
  }

  public func run(_ input: BrowserInspectInput, context: ToolContext) async -> ToolResultPayload {
    .browserInspect(await context.browserToolService.inspect(input))
  }
}
