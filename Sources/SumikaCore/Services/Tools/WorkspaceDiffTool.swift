import Darwin
import Foundation

package struct WorkspaceDiffInput: Codable, Equatable, Sendable {
  package let path: String?

  package init(path: String? = nil) {
    self.path = path
  }

  func resolve(in workspace: Workspace) throws -> URL {
    let path = path ?? "."
    if path.hasPrefix("/") || URL(string: path)?.scheme != nil {
      return try workspace.resolveAllowedPath(path)
    }
    // Encode relative names before validation so leading/trailing whitespace remains literal.
    return try workspace.resolveAllowedPath(workspace.rootURL.appending(path: path).absoluteString)
  }
}

package enum WorkspaceDiffResult: Codable, Equatable, Sendable {
  case snapshot(WorkspaceDiffSnapshot)
  case legacySuccess(path: WorkspaceRelativePath?, content: ToolTextOutput)
  case failed(path: WorkspaceRelativePath?, reason: ToolFailureReason)

  private enum CodingKeys: String, CodingKey { case snapshot, success, failed }
  private struct TextPayload: Codable {
    var path: WorkspaceRelativePath?
    var content: ToolTextOutput
  }
  private struct FailurePayload: Codable {
    var path: WorkspaceRelativePath?
    var reason: ToolFailureReason
  }

  package init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if container.contains(.snapshot) {
      self = .snapshot(try container.decode(WorkspaceDiffSnapshot.self, forKey: .snapshot))
    } else if container.contains(.success) {
      let payload = try container.decode(TextPayload.self, forKey: .success)
      self = .legacySuccess(path: payload.path, content: payload.content)
    } else {
      let payload = try container.decode(FailurePayload.self, forKey: .failed)
      self = .failed(path: payload.path, reason: payload.reason)
    }
  }

  package func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .snapshot(let snapshot):
      try container.encode(snapshot, forKey: .snapshot)
    case .legacySuccess(let path, let content):
      try container.encode(TextPayload(path: path, content: content), forKey: .success)
    case .failed(let path, let reason):
      try container.encode(FailurePayload(path: path, reason: reason), forKey: .failed)
    }
  }
}

package struct WorkspaceDiffSnapshot: Codable, Equatable, Sendable {
  var path: WorkspaceRelativePath?
  var files: [WorkspaceDiffFile]
}

struct WorkspaceDiffFile: Codable, Equatable, Sendable {
  var path: WorkspaceRelativePath
  var staged: WorkspaceDiffChange?
  var unstaged: WorkspaceDiffChange?

  var changes: [WorkspaceDiffChange] { [staged, unstaged].compactMap(\.self) }
  var truncated: Bool { changes.contains(where: \.patch.truncated) }
  var redacted: Bool { changes.contains(where: \.patch.redacted) }
}

struct WorkspaceDiffChange: Codable, Equatable, Sendable {
  enum Kind: String, Codable, Sendable {
    case added, modified, deleted, renamed, copied, typeChanged, unmerged, untracked
  }
  enum Omission: String, Codable, Sendable {
    case binary, symlink, submodule, conflict, budget
  }

  var kind: Kind
  var originalPath: WorkspaceRelativePath?
  var additions: Int?
  var deletions: Int?
  var patch: ToolTextOutput
  var omission: Omission?

  init(
    kind: Kind, originalPath: WorkspaceRelativePath? = nil,
    additions: Int? = nil, deletions: Int? = nil,
    patch: ToolTextOutput = ToolTextOutput(text: ""), omission: Omission? = nil
  ) {
    self.kind = kind
    self.originalPath = originalPath
    self.additions = additions
    self.deletions = deletions
    self.patch = patch
    self.omission = omission
  }
}

nonisolated extension WorkspaceDiffResult {
  var preview: ToolResultPreview {
    switch self {
    case .snapshot(let snapshot):
      let content = WorkspaceDiffPresentation.display(snapshot)
      return ToolResultPreview(
        text: content.text, truncated: content.truncated, redacted: content.redacted,
        affectedPaths: snapshot.files.isEmpty
          ? [snapshot.path ?? WorkspaceRelativePath(rawValue: ".")]
          : snapshot.files.map(\.path)
      )
    case .legacySuccess(let path, let content):
      return ToolResultPreview(
        text: content.text, truncated: content.truncated, redacted: content.redacted,
        affectedPaths: [path ?? WorkspaceRelativePath(rawValue: ".")]
      )
    case .failed(let path, let reason):
      return ToolResultPreview(
        status: reason.previewStatus, text: reason.message,
        affectedPaths: path.map { [$0] } ?? []
      )
    }
  }
}

nonisolated extension ToolDefinition {
  package static let workspaceDiff = ToolDefinition(
    name: .workspaceDiff,
    description: "Review staged, unstaged, and untracked changes with bounded per-file patches.",
    parameters: [
      ToolParameterDefinition(
        name: "path", description: "Workspace-relative path to scope the diff. Defaults to root.",
        isRequired: false
      )
    ],
    capabilities: [.readWorkspace], riskLevel: .low
  )
}

struct WorkspaceDiffToolExecutor: TypedToolExecutor {
  static let codec = ToolCodec<WorkspaceDiffInput>(
    definition: ToolDefinition.workspaceDiff,
    makePayload: ToolCallPayload.workspaceDiff,
    extractInput: { payload in
      guard case .workspaceDiff(let input) = payload else {
        throw ToolInputDecodingError.payloadMismatch(
          expected: ToolDefinition.workspaceDiff.name.rawValue, actual: payload.toolName.rawValue)
      }
      return input
    },
    validateInput: { try ToolArgumentValidation.validateOptionalPath($0.path) }
  )

  private static let defaultDirectGitExecutableURLs = [
    URL(filePath: "/Applications/Xcode.app/Contents/Developer/usr/bin/git")
  ]
  private static let defaultGitPathPrefixDirectories = [
    URL(filePath: "/opt/homebrew/bin"), URL(filePath: "/usr/local/bin"),
    URL(filePath: "/opt/local/bin"),
  ]
  private let gitExecutableURL: URL?
  private let directGitExecutableURLs: [URL]
  private let gitEnvironment: [String: String]
  private let gitPathPrefixDirectories: [URL]
  private let envExecutableURL: URL
  private let maxBytes: Int
  private let timeoutSeconds: Int
  private let requestTimeout: Duration
  private let processRunner: any CommandProcessRunning

  init(
    gitExecutableURL: URL? = nil, directGitExecutableURLs: [URL]? = nil,
    gitEnvironment: [String: String] = ProcessInfo.processInfo.environment,
    gitPathPrefixDirectories: [URL]? = nil,
    envExecutableURL: URL = URL(filePath: "/usr/bin/env"),
    maxBytes: Int = 48 * 1024, timeoutSeconds: Int = 10,
    requestTimeout: Duration = .seconds(30),
    processRunner: any CommandProcessRunning = DefaultCommandProcessRunner()
  ) {
    self.gitExecutableURL = gitExecutableURL
    self.directGitExecutableURLs = directGitExecutableURLs ?? Self.defaultDirectGitExecutableURLs
    self.gitEnvironment = gitEnvironment
    self.gitPathPrefixDirectories = gitPathPrefixDirectories ?? Self.defaultGitPathPrefixDirectories
    self.envExecutableURL = envExecutableURL
    self.maxBytes = max(0, maxBytes)
    self.timeoutSeconds = timeoutSeconds
    self.requestTimeout = requestTimeout
    self.processRunner = processRunner
  }

  func evaluatePermission(
    _ input: WorkspaceDiffInput, context: ToolContext
  ) -> ToolPermissionEvaluation {
    do {
      let resolvedPath = try input.resolve(in: context.workspace)
      return ToolPermissionEvaluation(
        decision: .allowed, reason: "Showing workspace diff is allowed.", riskLevel: .low,
        normalizedPaths: [resolvedPath.path(percentEncoded: false)],
        workspaceRelativePaths: [context.workspace.relativePath(for: resolvedPath)]
      )
    } catch {
      return ToolPermissionEvaluation(
        decision: .denied, reason: error.localizedDescription, riskLevel: .low)
    }
  }

  func run(_ input: WorkspaceDiffInput, context: ToolContext) async -> ToolResultPayload {
    var scopedPath: WorkspaceRelativePath?
    do {
      return try await context.workspace.withAsyncSecurityScopedAccess {
        let rootURL = try context.workspace.resolveAllowedPath(".")
        let scope = context.workspace.relativePath(
          for: try input.resolve(in: context.workspace))
        scopedPath = input.path == nil ? nil : scope
        let snapshot = try await withThrowingTaskGroup(of: WorkspaceDiffSnapshot.self) { group in
          group.addTask {
            try await collect(
              rootURL: rootURL, scope: scope, explicitScope: input.path != nil,
              workspace: context.workspace)
          }
          group.addTask {
            try await Task.sleep(for: requestTimeout)
            throw WorkspaceDiffError.message("workspace_diff request timed out.")
          }
          defer { group.cancelAll() }
          guard let snapshot = try await group.next() else { throw CancellationError() }
          return snapshot
        }
        return .workspaceDiff(.snapshot(snapshot))
      }
    } catch {
      let reason: ToolFailureReason
      if let failure = error as? WorkspaceDiffError {
        reason = .executionError(
          WorkspaceDiffPresentation.prefix(failure.localizedDescription, bytes: maxBytes))
      } else {
        reason = ToolResultFailureMapper.reason(from: error)
      }
      return .workspaceDiff(.failed(path: scopedPath, reason: reason))
    }
  }

  private func collect(
    rootURL: URL, scope: WorkspaceRelativePath, explicitScope: Bool, workspace: Workspace
  ) async throws -> WorkspaceDiffSnapshot {
    let command = makeGitCommand()
    let status = try await runGit(
      command, root: rootURL,
      arguments: [
        "status", "--porcelain=v2", "-z", "--untracked-files=all", "--find-renames=50%", "--",
        scope.rawValue,
      ])
    if status.stdoutData.isEmpty {
      return WorkspaceDiffSnapshot(path: explicitScope ? scope : nil, files: [])
    }
    let prefixResult = try await runGit(
      command, root: rootURL, arguments: ["rev-parse", "--show-prefix"])
    guard let prefix = String(data: prefixResult.stdoutData, encoding: .utf8),
      prefix.hasSuffix("\n")
    else {
      throw WorkspaceDiffError.invalidMetadata
    }
    var files = try WorkspaceDiffGitParser.inventory(
      status.stdoutData, repositoryPrefix: String(prefix.dropLast()), scope: scope.rawValue)
    let conflictedPaths = Set(
      files.filter { $0.changes.contains { $0.omission == .conflict } }.map(\.path.rawValue))
    let hasStaged = files.contains { $0.staged?.omission == nil && $0.staged != nil }
    let hasUnstaged = files.contains {
      $0.unstaged?.omission == nil && $0.unstaged != nil && $0.unstaged?.kind != .untracked
    }
    let statistics = try await withThrowingTaskGroup(
      of: (Bool, [String: WorkspaceDiffGitParser.Stat]).self
    ) { group in
      for staged in [true, false] where staged ? hasStaged : hasUnstaged {
        group.addTask {
          let result = try await runGit(
            command, root: rootURL,
            arguments: diffArguments(staged: staged) + ["--numstat", "-z", "--", scope.rawValue])
          return (
            staged,
            try WorkspaceDiffGitParser.statistics(
              result.stdoutData, conflictedPaths: conflictedPaths)
          )
        }
      }
      var values: [Bool: [String: WorkspaceDiffGitParser.Stat]] = [:]
      for try await (staged, stats) in group { values[staged] = stats }
      return values
    }
    for index in files.indices {
      for staged in [true, false] {
        guard var change = staged ? files[index].staged : files[index].unstaged,
          change.omission == nil, change.kind != .untracked
        else { continue }
        guard let stat = statistics[staged]?[files[index].path.rawValue] else {
          throw WorkspaceDiffError.message(
            "Workspace changed while collecting diff metadata; retry workspace_diff.")
        }
        change.additions = stat.additions
        change.deletions = stat.deletions
        if stat.binary { change.omission = .binary }
        if staged { files[index].staged = change } else { files[index].unstaged = change }
      }
    }
    let eligibleCount = files.filter { $0.changes.contains { $0.omission == nil } }.count
    let fileBudget = min(4 * 1024, maxBytes / max(1, eligibleCount))
    // Two files at a time bounds both process concurrency and retained read buffers.
    for start in stride(from: 0, to: files.count, by: 2) {
      try Task.checkCancellation()
      let batch = Array(files[start..<min(start + 2, files.count)])
      let completed = try await withThrowingTaskGroup(of: (Int, WorkspaceDiffFile).self) { group in
        for (offset, file) in batch.enumerated() {
          group.addTask {
            (
              offset,
              try await populatePatches(
                file, budget: fileBudget, command: command, root: rootURL, workspace: workspace)
            )
          }
        }
        var output: [(Int, WorkspaceDiffFile)] = []
        for try await item in group { output.append(item) }
        return output
      }
      for (offset, file) in completed { files[start + offset] = file }
    }
    return WorkspaceDiffSnapshot(path: explicitScope ? scope : nil, files: files)
  }

  private func populatePatches(
    _ input: WorkspaceDiffFile, budget: Int, command: GitLaunchCommand, root: URL,
    workspace: Workspace
  ) async throws -> WorkspaceDiffFile {
    var file = input
    let parts = file.changes.filter { $0.omission == nil }.count
    for staged in [true, false] {
      try Task.checkCancellation()
      guard var change = staged ? file.staged : file.unstaged, change.omission == nil else {
        continue
      }
      let allowance = budget / max(1, parts)
      if change.kind == .untracked {
        change = try await untrackedPreview(file.path, workspace: workspace, budget: allowance)
      } else if allowance == 0 {
        change.omission = .budget
        change.patch.truncated = true
      } else {
        var paths = [file.path.rawValue]
        if let oldPath = change.originalPath { paths.append(oldPath.rawValue) }
        for path in paths {
          _ = try workspace.resolveAllowedPath(root.appending(path: path).absoluteString)
        }
        let result = try await runGit(
          command, root: root,
          arguments: diffArguments(staged: staged)
            + [
              "--patch", "--unified=3", "--output-indicator-new=+", "--output-indicator-old=-",
              "--output-indicator-context= ", "--",
            ] + paths,
          stdoutLimit: allowance, metadata: false)
        let text =
          String(data: result.stdoutData, encoding: .utf8)
          ?? (result.stdoutTruncated ? WorkspaceDiffGitParser.partialUTF8(result.stdoutData) : nil)
        if let text {
          change.patch = ToolTextOutput(text: text, truncated: result.stdoutTruncated)
        } else {
          change.omission = .binary
          change.additions = nil
          change.deletions = nil
        }
      }
      if staged { file.staged = change } else { file.unstaged = change }
    }
    return file
  }

  private func untrackedPreview(
    _ path: WorkspaceRelativePath, workspace: Workspace, budget: Int
  ) async throws -> WorkspaceDiffChange {
    let task = Task.detached(priority: .userInitiated) {
      try workspace.withSecurityScopedAccess {
        try Task.checkCancellation()
        let candidate = workspace.rootURL.appending(path: path.rawValue)
        let values = try candidate.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        if values.isSymbolicLink == true {
          return WorkspaceDiffChange(kind: .untracked, omission: .symlink)
        }
        guard values.isRegularFile == true else {
          return WorkspaceDiffChange(kind: .untracked, omission: .submodule)
        }
        let url = try workspace.resolveAllowedPath(candidate.absoluteString)
        let descriptor = open(url.path(percentEncoded: false), O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
          throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
          throw WorkspaceDiffError.message("Untracked path changed before it could be read.")
        }
        var data = Data()
        while data.count < 64 * 1024 + 1 {
          try Task.checkCancellation()
          let chunk = try handle.read(upToCount: min(8192, 64 * 1024 + 1 - data.count)) ?? Data()
          if chunk.isEmpty { break }
          data.append(chunk)
        }
        let complete = data.count <= 64 * 1024
        if data.contains(0) { return WorkspaceDiffChange(kind: .untracked, omission: .binary) }
        let text: String
        if let decoded = String(data: data, encoding: .utf8) {
          text = decoded
        } else if !complete, let decoded = WorkspaceDiffGitParser.partialUTF8(data) {
          text = decoded
        } else {
          return WorkspaceDiffChange(kind: .untracked, omission: .binary)
        }
        let normalizedText = text.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalizedText.split(separator: "\n", omittingEmptySubsequences: false)
        if normalizedText.hasSuffix("\n") || normalizedText.isEmpty { lines.removeLast() }
        let patch = lines.map { "+" + $0 }.joined(separator: "\n")
        let limited = WorkspaceDiffPresentation.prefix(patch, bytes: budget)
        return WorkspaceDiffChange(
          kind: .untracked, additions: complete ? lines.count : nil, deletions: 0,
          patch: ToolTextOutput(
            text: limited, truncated: !complete || limited.utf8.count < patch.utf8.count),
          omission: budget == 0 && !data.isEmpty ? .budget : nil)
      }
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  private func diffArguments(staged: Bool) -> [String] {
    [
      "diff", "--no-ext-diff", "--no-textconv", "--no-color", "--relative", "--find-renames=50%",
      "--src-prefix=a/", "--dst-prefix=b/", "--diff-algorithm=myers", "--no-indent-heuristic",
      "--inter-hunk-context=0", "--submodule=short",
    ] + (staged ? ["--cached"] : [])
  }

  private func runGit(
    _ command: GitLaunchCommand, root: URL, arguments: [String],
    stdoutLimit: Int = 48 * 1024, metadata: Bool = true
  ) async throws -> CommandProcessResult {
    try Task.checkCancellation()
    var environment = command.environment ?? gitEnvironment
    for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_EXTERNAL_DIFF", "GIT_DIFF_OPTS"]
    {
      environment.removeValue(forKey: key)
    }
    let result = try await processRunner.run(
      CommandProcessRequest(
        executableURL: command.executableURL,
        arguments: command.leadingArguments
          + [
            "--no-optional-locks", "--literal-pathspecs", "-c", "core.fsmonitor=false",
            "-c", "diff.autoRefreshIndex=false", "-C", root.path(percentEncoded: false),
          ] + arguments,
        environment: environment, workingDirectoryURL: root, timeoutSeconds: timeoutSeconds,
        maxStdoutBytes: stdoutLimit, maxStderrBytes: 8 * 1024))
    try Task.checkCancellation()
    if result.cancelled { throw CancellationError() }
    if result.timedOut {
      throw WorkspaceDiffError.message("workspace_diff timed out after \(timeoutSeconds) seconds.")
    }
    guard result.exitCode == 0 else {
      let output = result.stderr.isEmpty ? result.stdout : result.stderr
      if output.localizedCaseInsensitiveContains("not a git repository") {
        throw WorkspaceDiffError.message("This workspace is not inside a Git repository.")
      }
      if output.localizedCaseInsensitiveContains(
        "xcrun: error: cannot be used within an App Sandbox")
      {
        throw WorkspaceDiffError.message(
          "The selected git executable invokes xcrun, which cannot run inside the App Sandbox. Make a real git executable available in the app PATH."
        )
      }
      throw WorkspaceDiffError.message(
        "git \(arguments.first ?? "command") exited with status \(result.exitCode.map(String.init) ?? "none"): \(output)"
      )
    }
    if metadata && result.stdoutTruncated { throw WorkspaceDiffError.metadataLimit }
    return result
  }

  private func makeGitCommand() -> GitLaunchCommand {
    if let gitExecutableURL {
      return GitLaunchCommand(
        executableURL: gitExecutableURL, leadingArguments: [], environment: nil)
    }
    if let url = directGitExecutableURLs.first(where: {
      FileManager.default.isExecutableFile(atPath: $0.path(percentEncoded: false))
    }) {
      return GitLaunchCommand(executableURL: url, leadingArguments: [], environment: nil)
    }
    return GitLaunchCommand(
      executableURL: envExecutableURL, leadingArguments: ["git"],
      environment: GitPathEnvironment(
        environment: gitEnvironment, prefixDirectories: gitPathPrefixDirectories
      ).resolvedEnvironment())
  }
}

private enum WorkspaceDiffError: Error, LocalizedError {
  case invalidMetadata, metadataLimit
  case message(String)

  var errorDescription: String? {
    switch self {
    case .invalidMetadata:
      "Git returned malformed workspace diff metadata. Retry with a narrower path."
    case .metadataLimit:
      "Workspace diff metadata exceeded its capture limit. Retry with a narrower path."
    case .message(let text): text
    }
  }
}

private enum WorkspaceDiffGitParser {
  struct Stat {
    var additions: Int?
    var deletions: Int?
    var binary: Bool
  }

  static func records(_ data: Data) throws -> [String] {
    guard data.isEmpty || data.last == 0, let string = String(data: data, encoding: .utf8) else {
      throw WorkspaceDiffError.invalidMetadata
    }
    return string.split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(
      String.init)
  }

  static func inventory(
    _ data: Data, repositoryPrefix: String, scope: String
  ) throws -> [WorkspaceDiffFile] {
    let records = try records(data)
    var files: [String: WorkspaceDiffFile] = [:]
    var index = 0
    func scoped(_ raw: String) throws -> String? {
      try scopedPath(raw, repositoryPrefix: repositoryPrefix, scope: scope)
    }
    while index < records.count {
      let record = records[index]
      index += 1
      if record.hasPrefix("# ") { continue }
      if record.hasPrefix("? ") {
        let raw = String(record.dropFirst(2))
        guard let path = try scoped(raw.hasSuffix("/") ? String(raw.dropLast()) : raw) else {
          continue
        }
        var file = files[path] ?? WorkspaceDiffFile(path: WorkspaceRelativePath(rawValue: path))
        guard file.unstaged == nil else { throw WorkspaceDiffError.invalidMetadata }
        file.unstaged = WorkspaceDiffChange(kind: .untracked)
        files[path] = file
        continue
      }
      let fields = try trackedFields(record)
      var path = try scoped(String(fields[fields.count - 1]))
      var originalPath: String?
      var crossesScope = false
      if record.first == "2" {
        guard index < records.count else { throw WorkspaceDiffError.invalidMetadata }
        originalPath = try scoped(records[index])
        index += 1
        if path == nil, let old = originalPath {
          path = old
          crossesScope = true
        } else if originalPath == nil {
          crossesScope = true
        }
      }
      guard let path else { continue }
      let codes = Array(fields[1])
      let omission: WorkspaceDiffChange.Omission?
      if record.first == "u" {
        omission = .conflict
      } else if fields[2].hasPrefix("S") {
        omission = .submodule
      } else if fields[3...5].contains("120000") {
        omission = .symlink
      } else {
        omission = nil
      }
      func change(_ code: Character) throws -> WorkspaceDiffChange? {
        if code == "." { return nil }
        let kind: WorkspaceDiffChange.Kind
        switch code {
        case "M": kind = .modified
        case "A": kind = .added
        case "D": kind = .deleted
        case "R": kind = crossesScope ? (originalPath == nil ? .added : .deleted) : .renamed
        case "C": kind = crossesScope ? .added : .copied
        case "T": kind = .typeChanged
        case "U": kind = .unmerged
        default: throw WorkspaceDiffError.invalidMetadata
        }
        return WorkspaceDiffChange(
          kind: record.first == "u" ? .unmerged : kind,
          originalPath: !crossesScope && (code == "R" || code == "C")
            ? originalPath.map(WorkspaceRelativePath.init(rawValue:)) : nil,
          omission: omission)
      }
      guard files[path] == nil else { throw WorkspaceDiffError.invalidMetadata }
      files[path] = WorkspaceDiffFile(
        path: WorkspaceRelativePath(rawValue: path), staged: try change(codes[0]),
        unstaged: try change(codes[1]))
    }
    return files.values.sorted {
      $0.path.rawValue.utf8.lexicographicallyPrecedes($1.path.rawValue.utf8)
    }
  }

  private static func trackedFields(_ record: String) throws -> [Substring] {
    let count: Int
    switch record.first {
    case "1": count = 8
    case "2": count = 9
    case "u": count = 10
    default: throw WorkspaceDiffError.invalidMetadata
    }
    let fields = record.split(separator: " ", maxSplits: count, omittingEmptySubsequences: false)
    guard fields.count == count + 1, fields[1].count == 2 else {
      throw WorkspaceDiffError.invalidMetadata
    }
    let modeEnd = record.first == "u" ? 6 : 5
    guard
      fields[3...modeEnd].allSatisfy({
        $0.count == 6 && $0.utf8.allSatisfy { (48...55).contains($0) }
      }), fields[2] == "N..." || (fields[2].count == 4 && fields[2].hasPrefix("S"))
    else {
      throw WorkspaceDiffError.invalidMetadata
    }
    return fields
  }

  private static func scopedPath(_ raw: String, repositoryPrefix: String, scope: String) throws
    -> String?
  {
    guard !raw.isEmpty, !raw.hasPrefix("/"), !raw.split(separator: "/").contains("..") else {
      throw WorkspaceDiffError.invalidMetadata
    }
    guard raw.hasPrefix(repositoryPrefix) else { return nil }
    let path = String(raw.dropFirst(repositoryPrefix.count))
    guard !path.isEmpty, scope == "." || path == scope || path.hasPrefix(scope + "/") else {
      return nil
    }
    return path
  }

  static func statistics(_ data: Data, conflictedPaths: Set<String>) throws -> [String: Stat] {
    let records = try records(data)
    var index = 0
    var stats: [String: Stat] = [:]
    while index < records.count {
      let fields = records[index].split(
        separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
      index += 1
      guard fields.count == 3 else { throw WorkspaceDiffError.invalidMetadata }
      let binary = fields[0] == "-" && fields[1] == "-"
      let additions = Int(fields[0])
      let deletions = Int(fields[1])
      guard binary || ((additions ?? -1) >= 0 && (deletions ?? -1) >= 0) else {
        throw WorkspaceDiffError.invalidMetadata
      }
      let path: String
      if fields[2].isEmpty {
        guard index + 1 < records.count else { throw WorkspaceDiffError.invalidMetadata }
        path = records[index + 1]
        index += 2
      } else {
        path = String(fields[2])
      }
      guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..")
      else { throw WorkspaceDiffError.invalidMetadata }
      if conflictedPaths.contains(path) { continue }
      guard stats[path] == nil else { throw WorkspaceDiffError.invalidMetadata }
      stats[path] = Stat(additions: additions, deletions: deletions, binary: binary)
    }
    return stats
  }

  static func partialUTF8(_ data: Data) -> String? {
    for dropped in 1...min(3, data.count) {
      if let string = String(data: data.dropLast(dropped), encoding: .utf8) { return string }
    }
    return nil
  }
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
