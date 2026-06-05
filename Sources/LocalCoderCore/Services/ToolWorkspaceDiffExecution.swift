import Foundation

public struct WorkspaceDiffInput: Codable, Equatable, Sendable {
  public let path: String?

  public init(path: String? = nil) {
    self.path = path
  }
}

public struct WorkspaceDiffToolExecutor: TypedToolExecutor {
  public static let definition = ToolDefinition.workspaceDiff

  private let gitExecutableURL: URL
  private let maxBytes: Int
  private let timeoutSeconds: Int

  public init(
    gitExecutableURL: URL = URL(filePath: "/usr/bin/git"),
    maxBytes: Int = 48 * 1024,
    timeoutSeconds: Int = 10
  ) {
    self.gitExecutableURL = gitExecutableURL
    self.maxBytes = maxBytes
    self.timeoutSeconds = timeoutSeconds
  }

  public func evaluatePermission(
    _ input: WorkspaceDiffInput,
    context: ToolContext
  ) -> ToolPermissionEvaluation {
    do {
      let resolvedPath = try context.workspace.resolveAllowedPath(input.path ?? ".")
      return ToolPermissionEvaluation(
        decision: .allowed,
        reason: "Showing workspace diff is allowed.",
        riskLevel: .low,
        normalizedPaths: [resolvedPath.path(percentEncoded: false)],
        workspaceRelativePaths: [context.workspace.relativePath(for: resolvedPath)]
      )
    } catch {
      return ToolPermissionEvaluation(
        decision: .denied,
        reason: error.localizedDescription,
        riskLevel: .low
      )
    }
  }

  public func run(_ input: WorkspaceDiffInput, context: ToolContext) async -> ToolResultPayload {
    var scopedPath: WorkspaceRelativePath?

    do {
      return try await context.workspace.withSecurityScopedAccess {
        let rootURL = try context.workspace.resolveAllowedPath(".")
        if let path = input.path {
          let resolvedURL = try context.workspace.resolveAllowedPath(path)
          scopedPath = context.workspace.relativePath(for: resolvedURL)
        }

        let pathArguments = scopedPath.map { [$0.rawValue] } ?? []
        let status = try await runGit(
          arguments: ["-C", rootURL.path(percentEncoded: false), "status", "--short", "--"]
            + pathArguments
        )
        guard !status.timedOut else {
          return timeoutResult(path: scopedPath)
        }
        guard status.exitCode == 0 else {
          return failureResult(path: scopedPath, command: "git status", result: status)
        }

        let stat = try await runGit(
          arguments: [
            "-C", rootURL.path(percentEncoded: false), "diff", "--no-ext-diff", "--stat", "--",
          ] + pathArguments
        )
        guard !stat.timedOut else {
          return timeoutResult(path: scopedPath)
        }
        guard stat.exitCode == 0 else {
          return failureResult(path: scopedPath, command: "git diff --stat", result: stat)
        }

        let diff = try await runGit(
          arguments: ["-C", rootURL.path(percentEncoded: false), "diff", "--no-ext-diff", "--"]
            + pathArguments
        )
        guard !diff.timedOut else {
          return timeoutResult(path: scopedPath)
        }
        guard diff.exitCode == 0 else {
          return failureResult(path: scopedPath, command: "git diff", result: diff)
        }

        let rendered = render(status: status.stdout, stat: stat.stdout, diff: diff.stdout)
        return .workspaceDiff(
          .success(path: scopedPath, content: cappedOutput(rendered, maxBytes: maxBytes))
        )
      }
    } catch {
      return .workspaceDiff(
        .failed(
          path: scopedPath,
          reason: ToolResultFailureMapper.reason(from: error)
        )
      )
    }
  }

  private func runGit(arguments: [String]) async throws -> GitCommandResult {
    let process = Process()
    process.executableURL = gitExecutableURL
    process.arguments = arguments

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    try process.run()

    let stdoutTask = Task {
      try stdoutPipe.fileHandleForReading.readToEnd() ?? Data()
    }
    let stderrTask = Task {
      try stderrPipe.fileHandleForReading.readToEnd() ?? Data()
    }
    let waitTask = Task {
      process.waitUntilExit()
      return process.terminationStatus
    }
    let timeoutTask = Task {
      try await Task.sleep(for: .seconds(timeoutSeconds))
      guard process.isRunning else {
        return false
      }
      process.terminate()
      return true
    }

    let exitCode = await waitTask.value
    timeoutTask.cancel()
    let timedOut = (try? await timeoutTask.value) ?? false
    let stdoutData = try await stdoutTask.value
    let stderrData = try await stderrTask.value

    return GitCommandResult(
      exitCode: exitCode,
      stdout: String(data: stdoutData, encoding: .utf8) ?? "",
      stderr: String(data: stderrData, encoding: .utf8) ?? "",
      timedOut: timedOut
    )
  }

  private func render(status: String, stat: String, diff: String) -> String {
    let status = trimmingTrailingWhitespace(status)
    let stat = trimmingTrailingWhitespace(stat)
    let diff = trimmingTrailingWhitespace(diff)

    guard !status.isEmpty else {
      return "No workspace changes."
    }

    var sections = ["Status:\n\(status)"]
    if !stat.isEmpty {
      sections.append("Diff stat:\n\(stat)")
    }
    if !diff.isEmpty {
      sections.append("Diff:\n\(diff)")
    }
    return sections.joined(separator: "\n\n")
  }

  private func failureResult(
    path: WorkspaceRelativePath?,
    command: String,
    result: GitCommandResult
  ) -> ToolResultPayload {
    let output = trimmingTrailingWhitespace(
      result.stderr.isEmpty ? result.stdout : result.stderr
    )
    let reason: String
    if output.localizedCaseInsensitiveContains("not a git repository") {
      reason = "This workspace is not inside a Git repository."
    } else if output.isEmpty {
      reason = "\(command) exited with status \(result.exitCode)."
    } else {
      reason = "\(command) exited with status \(result.exitCode): \(output)"
    }
    return .workspaceDiff(.failed(path: path, reason: .executionError(reason)))
  }

  private func timeoutResult(path: WorkspaceRelativePath?) -> ToolResultPayload {
    .workspaceDiff(
      .failed(
        path: path,
        reason: .executionError("workspace_diff timed out after \(timeoutSeconds) seconds.")
      ))
  }

  private func cappedOutput(_ text: String, maxBytes: Int) -> ToolTextOutput {
    let byteCount = text.utf8.count
    guard byteCount > maxBytes else {
      return ToolTextOutput(text: text)
    }

    let marker = "\n[workspace_diff output truncated]"
    let markerBytes = marker.utf8.count
    let prefixByteCount = max(maxBytes - markerBytes, 0)
    let prefixData = Data(text.utf8.prefix(prefixByteCount))
    let prefix = String(decoding: prefixData, as: UTF8.self)
    return ToolTextOutput(text: prefix + marker, truncated: true)
  }

  private func trimmingTrailingWhitespace(_ text: String) -> String {
    var text = text
    while let last = text.unicodeScalars.last, CharacterSet.whitespacesAndNewlines.contains(last) {
      text.unicodeScalars.removeLast()
    }
    return text
  }
}

private struct GitCommandResult: Equatable, Sendable {
  var exitCode: Int32
  var stdout: String
  var stderr: String
  var timedOut: Bool
}
