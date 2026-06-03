import Foundation

public struct ToolPermissionEvaluator: Sendable {
  public init() {}

  public func evaluate(_ request: ToolCallRequest, in workspace: Workspace)
    -> ToolPermissionEvaluation
  {
    guard request.workspaceID == workspace.id else {
      return ToolPermissionEvaluation(
        decision: .denied,
        reason: "Tool call workspace does not match the active workspace.",
        riskLevel: .high
      )
    }

    switch request.payload {
    case .listFiles(let input):
      return evaluatePathTool(
        paths: [input.path ?? "."],
        in: workspace,
        decision: .allowed,
        riskLevel: .low,
        successReason: "Listing files inside the workspace is allowed."
      )
    case .globFiles(let input):
      return evaluatePathTool(
        paths: [input.path ?? "."],
        in: workspace,
        decision: .allowed,
        riskLevel: .low,
        successReason: "Finding files inside the workspace is allowed."
      )
    case .readFile(let input):
      return evaluatePathTool(
        paths: [input.path],
        in: workspace,
        decision: .allowed,
        riskLevel: .low,
        successReason: "Reading files inside the workspace is allowed."
      )
    case .searchFiles(let input):
      return evaluatePathTool(
        paths: [input.path ?? "."],
        in: workspace,
        decision: .allowed,
        riskLevel: .low,
        successReason: "Searching files inside the workspace is allowed."
      )
    case .writeFile(let input):
      return evaluatePathTool(
        paths: [input.path],
        in: workspace,
        decision: .requiresApproval,
        riskLevel: .high,
        successReason: "Writing files inside the workspace requires approval."
      )
    case .editFile(let input):
      return evaluatePathTool(
        paths: [input.path],
        in: workspace,
        decision: .requiresApproval,
        riskLevel: .high,
        successReason: "Editing files inside the workspace requires approval."
      )
    case .invalid(let input):
      return ToolPermissionEvaluation(
        decision: .denied,
        reason: input.reason.message,
        riskLevel: .high
      )
    }
  }

  private func evaluatePathTool(
    paths: [String],
    in workspace: Workspace,
    decision: ToolPermissionDecision,
    riskLevel: ToolRiskLevel,
    successReason: String
  ) -> ToolPermissionEvaluation {
    do {
      let normalizedPaths = try paths.map {
        try workspace.resolveAllowedPath($0).path(percentEncoded: false)
      }

      return ToolPermissionEvaluation(
        decision: decision,
        reason: successReason,
        riskLevel: riskLevel,
        normalizedPaths: normalizedPaths
      )
    } catch {
      return ToolPermissionEvaluation(
        decision: .denied,
        reason: error.localizedDescription,
        riskLevel: riskLevel
      )
    }
  }
}
