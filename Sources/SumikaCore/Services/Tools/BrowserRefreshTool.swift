import Foundation

public struct BrowserRefreshToolExecutor: TypedToolExecutor {
  public static let definition = ToolDefinition.browserRefresh

  public init() {}

  public static func input(from payload: ToolCallPayload) throws -> BrowserRefreshInput {
    guard case .browserRefresh(let input) = payload else {
      throw ToolInputDecodingError.payloadMismatch(
        expected: definition.name.rawValue,
        actual: payload.toolName.rawValue
      )
    }
    return input
  }

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
