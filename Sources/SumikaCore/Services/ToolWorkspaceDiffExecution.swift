import Foundation

public struct WorkspaceDiffInput: Codable, Equatable, Sendable {
  public let path: String?

  public init(path: String? = nil) {
    self.path = path
  }
}

public struct WorkspaceDiffToolExecutor: TypedToolExecutor {
  public static let definition = ToolDefinition.workspaceDiff

  private static let defaultDirectGitExecutableURLs = [
    URL(filePath: "/Applications/Xcode.app/Contents/Developer/usr/bin/git")
  ]

  private static let defaultGitPathPrefixDirectories = [
    URL(filePath: "/opt/homebrew/bin"),
    URL(filePath: "/usr/local/bin"),
    URL(filePath: "/opt/local/bin"),
  ]

  private let gitExecutableURL: URL?
  private let directGitExecutableURLs: [URL]
  private let gitEnvironment: [String: String]
  private let gitPathPrefixDirectories: [URL]
  private let envExecutableURL: URL
  private let maxBytes: Int
  private let timeoutSeconds: Int

  public init(
    gitExecutableURL: URL? = nil,
    directGitExecutableURLs: [URL]? = nil,
    gitEnvironment: [String: String] = ProcessInfo.processInfo.environment,
    gitPathPrefixDirectories: [URL]? = nil,
    envExecutableURL: URL = URL(filePath: "/usr/bin/env"),
    maxBytes: Int = 48 * 1024,
    timeoutSeconds: Int = 10
  ) {
    self.gitExecutableURL = gitExecutableURL
    self.directGitExecutableURLs = directGitExecutableURLs ?? Self.defaultDirectGitExecutableURLs
    self.gitEnvironment = gitEnvironment
    self.gitPathPrefixDirectories = gitPathPrefixDirectories ?? Self.defaultGitPathPrefixDirectories
    self.envExecutableURL = envExecutableURL
    self.maxBytes = maxBytes
    self.timeoutSeconds = timeoutSeconds
  }

  public static func input(from payload: ToolCallPayload) throws -> WorkspaceDiffInput {
    guard case .workspaceDiff(let input) = payload else {
      throw ToolInputDecodingError.payloadMismatch(
        expected: definition.name.rawValue,
        actual: payload.toolName.rawValue
      )
    }
    return input
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
      return try await context.workspace.withAsyncSecurityScopedAccess {
        let rootURL = try context.workspace.resolveAllowedPath(".")
        let gitCommand = makeGitCommand()
        if let path = input.path {
          let resolvedURL = try context.workspace.resolveAllowedPath(path)
          scopedPath = context.workspace.relativePath(for: resolvedURL)
        }

        let pathArguments = scopedPath.map { [$0.rawValue] } ?? []
        let status = try await runGit(
          command: gitCommand,
          arguments: configuredGitArguments(
            ["-C", rootURL.path(percentEncoded: false), "status", "--short", "--"]
              + pathArguments)
        )
        guard !status.timedOut else {
          return timeoutResult(path: scopedPath)
        }
        guard status.exitCode == 0 else {
          return failureResult(path: scopedPath, command: "git status", result: status)
        }

        let stat = try await runGit(
          command: gitCommand,
          arguments: configuredGitArguments(
            [
              "-C", rootURL.path(percentEncoded: false), "diff", "--no-ext-diff", "--stat", "--",
            ] + pathArguments)
        )
        guard !stat.timedOut else {
          return timeoutResult(path: scopedPath)
        }
        guard stat.exitCode == 0 else {
          return failureResult(path: scopedPath, command: "git diff --stat", result: stat)
        }

        let diff = try await runGit(
          command: gitCommand,
          arguments: configuredGitArguments(
            ["-C", rootURL.path(percentEncoded: false), "diff", "--no-ext-diff", "--"]
              + pathArguments)
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

  private func makeGitCommand() -> GitLaunchCommand {
    if let gitExecutableURL {
      return GitLaunchCommand(
        executableURL: gitExecutableURL,
        leadingArguments: [],
        environment: nil
      )
    }

    if let directGitExecutableURL = directGitExecutableURLs.first(where: {
      FileManager.default.isExecutableFile(atPath: $0.path(percentEncoded: false))
    }) {
      return GitLaunchCommand(
        executableURL: directGitExecutableURL,
        leadingArguments: [],
        environment: nil
      )
    }

    return GitLaunchCommand(
      executableURL: envExecutableURL,
      leadingArguments: ["git"],
      environment: GitPathEnvironment(
        environment: gitEnvironment,
        prefixDirectories: gitPathPrefixDirectories
      ).resolvedEnvironment()
    )
  }

  private func configuredGitArguments(_ arguments: [String]) -> [String] {
    ["-c", "core.fsmonitor=false"] + arguments
  }

  private func runGit(command: GitLaunchCommand, arguments: [String]) async throws
    -> GitCommandResult
  {
    let process = Process()
    process.executableURL = command.executableURL
    process.arguments = command.leadingArguments + arguments
    if let environment = command.environment {
      process.environment = environment
    }

    let outputID = UUID().uuidString
    let temporaryDirectory = FileManager.default.temporaryDirectory
    let stdoutURL = temporaryDirectory.appending(
      path: "sumika-workspace-diff-\(outputID).stdout")
    let stderrURL = temporaryDirectory.appending(
      path: "sumika-workspace-diff-\(outputID).stderr")
    try Data().write(to: stdoutURL)
    try Data().write(to: stderrURL)

    let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
    let stderrHandle = try FileHandle(forWritingTo: stderrURL)
    var outputHandlesClosed = false
    func closeOutputHandles() {
      guard !outputHandlesClosed else {
        return
      }
      outputHandlesClosed = true
      try? stdoutHandle.close()
      try? stderrHandle.close()
    }
    defer {
      closeOutputHandles()
      try? FileManager.default.removeItem(at: stdoutURL)
      try? FileManager.default.removeItem(at: stderrURL)
    }

    process.standardOutput = stdoutHandle
    process.standardError = stderrHandle

    let timeoutTask = Task {
      try await Task.sleep(for: .seconds(timeoutSeconds))
      guard process.isRunning else {
        return false
      }
      process.terminate()
      return true
    }

    let exitCode = try await runProcessAndWaitForExit(process)
    timeoutTask.cancel()
    let timedOut = (try? await timeoutTask.value) ?? false
    closeOutputHandles()
    let stdoutData = try Data(contentsOf: stdoutURL)
    let stderrData = try Data(contentsOf: stderrURL)

    return GitCommandResult(
      exitCode: exitCode,
      stdout: String(data: stdoutData, encoding: .utf8) ?? "",
      stderr: String(data: stderrData, encoding: .utf8) ?? "",
      timedOut: timedOut
    )
  }

  private func runProcessAndWaitForExit(_ process: Process) async throws -> Int32 {
    try await withCheckedThrowingContinuation { continuation in
      process.terminationHandler = { process in
        continuation.resume(returning: process.terminationStatus)
      }

      do {
        try process.run()
      } catch {
        process.terminationHandler = nil
        continuation.resume(throwing: error)
      }
    }
  }

  private func render(status: String, stat: String, diff: String) -> String {
    let status = formattedStatus(status)
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

  private func formattedStatus(_ status: String) -> String {
    let lines = trimmingTrailingWhitespace(status)
      .split(separator: "\n", omittingEmptySubsequences: true)
      .map(String.init)
    guard !lines.isEmpty else {
      return ""
    }

    var groups: [(label: String, paths: [String])] = []
    for line in lines {
      let entry = formattedStatusEntry(line)
      if let index = groups.firstIndex(where: { $0.label == entry.label }) {
        groups[index].paths.append(entry.path)
      } else {
        groups.append((label: entry.label, paths: [entry.path]))
      }
    }

    return groups.map { group in
      let paths = group.paths.map { "  \($0)" }.joined(separator: "\n")
      return "\(group.label):\n\(paths)"
    }.joined(separator: "\n")
  }

  private func formattedStatusEntry(_ line: String) -> (label: String, path: String) {
    guard line.count >= 3 else {
      return ("Changes", line)
    }

    let code = String(line.prefix(2))
    let path = String(line.dropFirst(3))

    if code == "??" {
      return ("Untracked", path)
    }
    if code == "!!" {
      return ("Ignored", path)
    }

    let indexStatus = code.first ?? " "
    let worktreeStatus = code.dropFirst().first ?? " "
    return (statusLabel(indexStatus: indexStatus, worktreeStatus: worktreeStatus), path)
  }

  private func statusLabel(indexStatus: Character, worktreeStatus: Character) -> String {
    if indexStatus != " ", worktreeStatus != " " {
      return "Staged and unstaged changes"
    }

    if worktreeStatus != " " {
      switch worktreeStatus {
      case "M": return "Modified"
      case "D": return "Deleted"
      case "A": return "Added"
      case "R": return "Renamed"
      case "C": return "Copied"
      case "U": return "Unmerged"
      default: return "Changes"
      }
    }

    switch indexStatus {
    case "M": return "Staged modified"
    case "D": return "Staged deleted"
    case "A": return "Staged added"
    case "R": return "Staged renamed"
    case "C": return "Staged copied"
    case "U": return "Unmerged"
    default: return "Changes"
    }
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
    } else if output.localizedCaseInsensitiveContains(
      "xcrun: error: cannot be used within an App Sandbox"
    ) {
      reason =
        "The selected git executable invokes xcrun, which cannot run inside the App Sandbox. "
        + "Make a real git executable available in the app PATH."
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
    let prefix = utf8StringDroppingPartialSuffix(from: prefixData)
    return ToolTextOutput(text: prefix + marker, truncated: true)
  }

  private func utf8StringDroppingPartialSuffix(from data: Data) -> String {
    if let string = String(bytes: data, encoding: .utf8) {
      return string
    }

    guard !data.isEmpty else {
      return ""
    }

    for droppedByteCount in 1...min(3, data.count) {
      let shortenedData = data.dropLast(droppedByteCount)
      if let string = String(bytes: shortenedData, encoding: .utf8) {
        return string
      }
    }

    return ""
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

private struct GitLaunchCommand: Equatable, Sendable {
  var executableURL: URL
  var leadingArguments: [String]
  var environment: [String: String]?
}

struct GitPathEnvironment: Sendable {
  private let environment: [String: String]
  private let prefixDirectories: [URL]

  init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    prefixDirectories: [URL]
  ) {
    self.environment = environment
    self.prefixDirectories = prefixDirectories
  }

  func resolvedEnvironment() -> [String: String] {
    var environment = environment
    environment["PATH"] = resolvedPath()
    return environment
  }

  func resolvedPath() -> String {
    let path = environment["PATH"] ?? ""
    let pathDirectories =
      path
      .split(separator: ":", omittingEmptySubsequences: true)
      .map { URL(filePath: String($0)) }
    let directories = prefixDirectories + pathDirectories
    var seenPaths = Set<String>()
    var resolvedComponents: [String] = []

    for directory in directories {
      let path = normalizedPath(directory)
      guard !seenPaths.contains(path) else {
        continue
      }
      seenPaths.insert(path)
      resolvedComponents.append(path)
    }

    return resolvedComponents.joined(separator: ":")
  }

  private func normalizedPath(_ url: URL) -> String {
    url.standardizedFileURL.path(percentEncoded: false)
  }
}
