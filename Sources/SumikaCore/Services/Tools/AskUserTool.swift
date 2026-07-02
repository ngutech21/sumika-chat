import Foundation

public struct AskUserToolExecutor: TypedToolExecutor {
  public static let definition = ToolDefinition.askUser

  public init() {}

  public static func input(from payload: ToolCallPayload) throws -> AskUserInput {
    guard case .askUser(let input) = payload else {
      throw ToolInputDecodingError.payloadMismatch(
        expected: definition.name.rawValue,
        actual: payload.toolName.rawValue
      )
    }
    return input
  }

  public func evaluatePermission(
    _ input: AskUserInput,
    context: ToolContext
  ) -> ToolPermissionEvaluation {
    _ = input
    _ = context
    return ToolPermissionEvaluation(
      decision: .allowed,
      reason: "Asking the user a blocking clarification is allowed.",
      riskLevel: .low
    )
  }

  public func run(_ input: AskUserInput, context: ToolContext) async -> ToolResultPayload {
    _ = input
    _ = context
    return .failure(
      ToolFailure(
        toolName: .askUser,
        path: nil,
        reason: .executionError("ask_user must be answered by the user before it completes.")
      )
    )
  }
}
