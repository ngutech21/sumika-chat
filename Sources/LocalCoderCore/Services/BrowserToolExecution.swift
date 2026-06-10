import Foundation

public protocol BrowserToolServing: Sendable {
  func refresh(_ input: BrowserRefreshInput) async -> BrowserRefreshResult
  func inspect(_ input: BrowserInspectInput) async -> BrowserInspectResult
}

public struct UnavailableBrowserToolService: BrowserToolServing {
  public init() {}

  public func refresh(_ input: BrowserRefreshInput) async -> BrowserRefreshResult {
    _ = input
    return .failed(reason: .executionError(Self.unavailableMessage))
  }

  public func inspect(_ input: BrowserInspectInput) async -> BrowserInspectResult {
    _ = input
    return .failed(reason: .executionError(Self.unavailableMessage))
  }

  public static let unavailableMessage =
    "HTML preview is not available. Open a preview with /preview <path-to-html-file> first."
}

public struct BrowserRefreshToolExecutor: TypedToolExecutor {
  public static let definition = ToolDefinition.browserRefresh

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

public struct BrowserInspectToolExecutor: TypedToolExecutor {
  public static let definition = ToolDefinition.browserInspect

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
