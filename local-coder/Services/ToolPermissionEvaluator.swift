import Foundation

nonisolated struct ToolPermissionEvaluator: Sendable {
  func evaluate(_ request: ToolCallRequest, in workspace: Workspace) -> ToolPermissionEvaluation {
    guard request.workspaceID == workspace.id else {
      return ToolPermissionEvaluation(
        decision: .denied,
        reason: "Tool call workspace does not match the active workspace.",
        riskLevel: .high
      )
    }

    switch request.toolName {
    case .listFiles:
      return evaluatePathTool(
        request,
        in: workspace,
        argumentKeys: ["path", "paths"],
        defaultPaths: ["."],
        decision: .allowed,
        riskLevel: .low,
        successReason: "Listing files inside the workspace is allowed."
      )
    case .globFiles:
      return evaluatePathTool(
        request,
        in: workspace,
        argumentKeys: ["path"],
        defaultPaths: ["."],
        decision: .allowed,
        riskLevel: .low,
        successReason: "Finding files inside the workspace is allowed."
      )
    case .readFile:
      return evaluatePathTool(
        request,
        in: workspace,
        argumentKeys: ["path", "paths"],
        decision: .allowed,
        riskLevel: .low,
        successReason: "Reading files inside the workspace is allowed."
      )
    case .searchFiles:
      return evaluatePathTool(
        request,
        in: workspace,
        argumentKeys: ["path"],
        defaultPaths: ["."],
        decision: .allowed,
        riskLevel: .low,
        successReason: "Searching files inside the workspace is allowed."
      )
    case .writeFile:
      return evaluatePathTool(
        request,
        in: workspace,
        argumentKeys: ["path"],
        decision: .requiresApproval,
        riskLevel: .high,
        successReason: "Writing files inside the workspace requires approval."
      )
    case .editFile:
      return evaluatePathTool(
        request,
        in: workspace,
        argumentKeys: ["path"],
        decision: .requiresApproval,
        riskLevel: .high,
        successReason: "Editing files inside the workspace requires approval."
      )
    case .applyPatch:
      return evaluatePathTool(
        request,
        in: workspace,
        argumentKeys: ["affectedPaths", "affected_paths"],
        decision: .requiresApproval,
        riskLevel: .high,
        successReason: "Applying a patch inside the workspace requires approval.",
        missingPathReason: "apply_patch requires affectedPaths."
      )
    case .runCommand:
      return evaluatePathTool(
        request,
        in: workspace,
        argumentKeys: ["workingDirectory", "working_directory"],
        decision: .requiresApproval,
        riskLevel: .high,
        successReason: "Running a command inside the workspace requires approval.",
        missingPathReason: "run_command requires a workingDirectory."
      )
    default:
      return ToolPermissionEvaluation(
        decision: .denied,
        reason: "Unknown tool: \(request.toolName.rawValue).",
        riskLevel: .high
      )
    }
  }

  private func evaluatePathTool(
    _ request: ToolCallRequest,
    in workspace: Workspace,
    argumentKeys: [String],
    defaultPaths: [String] = [],
    decision: ToolPermissionDecision,
    riskLevel: ToolRiskLevel,
    successReason: String,
    missingPathReason: String = "Tool requires at least one workspace path."
  ) -> ToolPermissionEvaluation {
    guard let paths = paths(from: request.arguments, keys: argumentKeys, defaultPaths: defaultPaths)
    else {
      return ToolPermissionEvaluation(
        decision: .denied,
        reason: missingPathReason,
        riskLevel: riskLevel
      )
    }

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

  private func paths(
    from arguments: ToolCallArguments,
    keys: [String],
    defaultPaths: [String]
  ) -> [String]? {
    for key in keys {
      guard let value = arguments[key] else {
        continue
      }

      return stringPaths(from: value)
    }

    return defaultPaths.isEmpty ? nil : defaultPaths
  }

  private func stringPaths(from value: ToolArgumentValue) -> [String]? {
    switch value {
    case .string(let path):
      return [path]
    case .array(let values):
      var paths: [String] = []
      for value in values {
        guard case .string(let path) = value else {
          return nil
        }
        paths.append(path)
      }
      return paths.isEmpty ? nil : paths
    default:
      return nil
    }
  }
}
