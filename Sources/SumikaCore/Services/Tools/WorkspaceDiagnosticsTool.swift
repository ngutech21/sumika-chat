import Foundation

public struct WorkspaceDiagnosticsToolExecutor: TypedToolExecutor {
  public static let definition = ToolDefinition.workspaceDiagnostics

  public init() {}

  public static func input(from payload: ToolCallPayload) throws -> WorkspaceDiagnosticsInput {
    guard case .workspaceDiagnostics(let input) = payload else {
      throw ToolInputDecodingError.payloadMismatch(
        expected: definition.name.rawValue,
        actual: payload.toolName.rawValue
      )
    }
    return input
  }

  public func evaluatePermission(
    _ input: WorkspaceDiagnosticsInput,
    context: ToolContext
  ) -> ToolPermissionEvaluation {
    ToolPermissionEvaluation(
      decision: .allowed,
      reason: "Reading command diagnostics is allowed.",
      riskLevel: .low,
      workspaceRelativePaths: [WorkspaceRelativePath(rawValue: ".")]
    )
  }

  public func run(
    _ input: WorkspaceDiagnosticsInput,
    context: ToolContext
  ) async -> ToolResultPayload {
    guard let sessionID = context.sessionID else {
      return .failure(
        ToolFailure(
          toolName: .workspaceDiagnostics,
          path: nil,
          reason: .executionError("workspace_diagnostics requires a session.")
        )
      )
    }

    guard
      let output = await context.latestCommandResultStore?.output(
        outputRef: input.outputRef,
        workspaceID: context.workspace.id,
        sessionID: sessionID
      )
    else {
      return .failure(
        ToolFailure(
          toolName: .workspaceDiagnostics,
          path: nil,
          reason: .executionError("Command output not found: \(input.outputRef).")
        )
      )
    }

    let diagnostics = Self.parseDiagnostics(
      text: output.stdout + "\n" + output.stderr,
      workspace: context.workspace
    )
    return .workspaceDiagnostics(
      WorkspaceDiagnosticsResult(outputRef: input.outputRef, diagnostics: diagnostics)
    )
  }

  public static func parseDiagnostics(text: String, workspace: Workspace) -> [WorkspaceDiagnostic] {
    text.split(whereSeparator: \.isNewline).compactMap { line in
      parseDiagnosticLine(String(line), workspace: workspace)
    }
  }

  private static func parseDiagnosticLine(
    _ line: String,
    workspace: Workspace
  ) -> WorkspaceDiagnostic? {
    for severity in [
      WorkspaceDiagnosticSeverity.error,
      .warning,
      .note,
    ] {
      let marker = ": \(severity.rawValue): "
      guard let markerRange = line.range(of: marker, options: [.caseInsensitive]) else {
        continue
      }

      let location = String(line[..<markerRange.lowerBound])
      let message = line[markerRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
      guard !message.isEmpty,
        let parsed = parseLocation(location)
      else {
        return nil
      }

      do {
        let resolvedURL = try workspace.resolveAllowedPath(parsed.path)
        return WorkspaceDiagnostic(
          path: workspace.relativePath(for: resolvedURL),
          line: parsed.line,
          column: parsed.column,
          severity: severity,
          message: message
        )
      } catch {
        return nil
      }
    }

    return nil
  }

  private struct ParsedLocation {
    let path: String
    let line: Int
    let column: Int?
  }

  private static func parseLocation(_ location: String) -> ParsedLocation? {
    let parts = location.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count >= 2,
      let lastNumber = Int(parts[parts.count - 1]),
      lastNumber > 0
    else {
      return nil
    }

    if parts.count >= 3,
      let line = Int(parts[parts.count - 2]),
      line > 0
    {
      let path = parts.dropLast(2).joined(separator: ":")
      guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        lastNumber > 0
      else {
        return nil
      }
      return ParsedLocation(path: path, line: line, column: lastNumber)
    }

    let path = parts.dropLast(1).joined(separator: ":")
    guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }
    return ParsedLocation(path: path, line: lastNumber, column: nil)
  }
}
