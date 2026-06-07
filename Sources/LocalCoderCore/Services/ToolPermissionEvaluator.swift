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
    case .showFile(let input):
      return evaluatePathTool(
        paths: [input.path],
        in: workspace,
        decision: .allowed,
        riskLevel: .low,
        successReason: "Displaying files inside the workspace is allowed."
      )
    case .searchFiles(let input):
      return evaluatePathTool(
        paths: [input.path ?? "."],
        in: workspace,
        decision: .allowed,
        riskLevel: .low,
        successReason: "Searching files inside the workspace is allowed."
      )
    case .workspaceDiff(let input):
      return evaluatePathTool(
        paths: [input.path ?? "."],
        in: workspace,
        decision: .allowed,
        riskLevel: .low,
        successReason: "Showing workspace diff is allowed."
      )
    case .workspaceDiagnostics:
      return ToolPermissionEvaluation(
        decision: .allowed,
        reason: "Reading command diagnostics is allowed.",
        riskLevel: .low,
        workspaceRelativePaths: [WorkspaceRelativePath(rawValue: ".")]
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
    case .runCommand:
      return evaluatePathTool(
        paths: ["."],
        in: workspace,
        decision: .requiresApproval,
        riskLevel: .high,
        successReason: "Running commands inside the workspace requires approval."
      )
    case .todoWrite:
      return ToolPermissionEvaluation(
        decision: .allowed,
        reason: "Updating Agent todo state is allowed.",
        riskLevel: .low
      )
    case .askUser:
      return ToolPermissionEvaluation(
        decision: .allowed,
        reason: "Asking the user a blocking clarification is allowed.",
        riskLevel: .low
      )
    case .webSearch, .webFetch:
      return ToolPermissionEvaluation(
        decision: .denied,
        reason: "Web access policy is evaluated by the web tool executor.",
        riskLevel: .high
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
      let resolvedPaths = try paths.map {
        try workspace.resolveAllowedPath($0)
      }
      let normalizedPaths = resolvedPaths.map { $0.path(percentEncoded: false) }
      let workspaceRelativePaths = resolvedPaths.map { workspace.relativePath(for: $0) }

      return ToolPermissionEvaluation(
        decision: decision,
        reason: successReason,
        riskLevel: riskLevel,
        normalizedPaths: normalizedPaths,
        workspaceRelativePaths: workspaceRelativePaths
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
