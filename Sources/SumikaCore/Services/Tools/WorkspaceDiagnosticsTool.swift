import Foundation

package struct WorkspaceDiagnosticsInput: Codable, Equatable, Sendable {
  package var outputRef: String

  package init(outputRef: String) {
    self.outputRef = outputRef
  }
}

package struct WorkspaceDiagnosticsResult: Codable, Equatable, Sendable {
  package var outputRef: String
  package var diagnostics: [WorkspaceDiagnostic]

  package init(outputRef: String, diagnostics: [WorkspaceDiagnostic]) {
    self.outputRef = outputRef
    self.diagnostics = diagnostics
  }
}

nonisolated extension WorkspaceDiagnosticsResult {
  var preview: ToolResultPreview {
    guard !diagnostics.isEmpty else {
      return ToolResultPreview(text: "No diagnostics found for \(outputRef).")
    }

    let lines = diagnostics.map { diagnostic in
      let column = diagnostic.column.map { ":\($0)" } ?? ""
      return
        "\(diagnostic.path.rawValue):\(diagnostic.line)\(column): \(diagnostic.severity.rawValue): \(diagnostic.message)"
    }
    return ToolResultPreview(
      text: lines.joined(separator: "\n"),
      affectedPaths: diagnostics.map(\.path.rawValue)
    )
  }
}

nonisolated extension ToolDefinition {
  package static let workspaceDiagnostics = ToolDefinition(
    name: .workspaceDiagnostics,
    description:
      "Extract compiler, linter, and test diagnostics from a previous run_command outputRef. Use after build, test, lint, or typecheck commands to get structured file/line/column errors before editing.",
    parameters: [
      ToolParameterDefinition(
        name: "outputRef",
        description:
          "The outputRef returned by run_command, e.g. cmd_abc123. Must refer to the command whose stdout/stderr should be parsed.",
        isRequired: true
      )
    ],
    capabilities: [.readWorkspace],
    riskLevel: .low
  )
}

struct WorkspaceDiagnosticsToolExecutor: TypedToolExecutor {
  static let codec = ToolCodec<WorkspaceDiagnosticsInput>(
    definition: ToolDefinition.workspaceDiagnostics,
    makePayload: ToolCallPayload.workspaceDiagnostics,
    extractInput: { payload in
      guard case .workspaceDiagnostics(let input) = payload else {
        throw ToolInputDecodingError.payloadMismatch(
          expected: ToolDefinition.workspaceDiagnostics.name.rawValue,
          actual: payload.toolName.rawValue
        )
      }
      return input
    },
    validateInput: { input in
      try ToolArgumentValidation.requireNonEmptyString(
        input.outputRef,
        name: "outputRef",
        expected: "a non-empty command output ref"
      )
    }
  )

  func evaluatePermission(
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

  func run(
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

  internal static func parseDiagnostics(
    text: String,
    workspace: Workspace
  ) -> [WorkspaceDiagnostic] {
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
