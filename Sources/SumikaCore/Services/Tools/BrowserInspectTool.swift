import Foundation

public struct BrowserInspectToolExecutor: TypedToolExecutor {
  public static let definition = ToolDefinition.browserInspect

  public init() {}

  public static func input(from payload: ToolCallPayload) throws -> BrowserInspectInput {
    guard case .browserInspect(let input) = payload else {
      throw ToolInputDecodingError.payloadMismatch(
        expected: definition.name.rawValue,
        actual: payload.toolName.rawValue
      )
    }
    return input
  }

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
