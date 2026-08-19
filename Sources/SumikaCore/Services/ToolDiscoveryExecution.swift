import Foundation

#if canImport(OSLog)
  import OSLog
#endif

internal struct WorkspaceFileDiscovery: Sendable {
  package static let excludedNames: Set<String> = [
    ".git", ".DS_Store", "DerivedData", ".build", "build", ".swiftpm", "node_modules",
  ]

  package struct DiscoveredFile: Equatable, Sendable {
    package var url: URL
    package var relativePath: String
  }

  package struct DiscoveredEntry: Equatable, Sendable {
    package var url: URL
    package var relativePath: String
    package var kind: WorkspaceFileKind
  }

  private enum RepositoryState: Sendable {
    case repository
    case fallback(String)
  }

  private enum IgnoreCheck: Sendable {
    case ignored(Set<String>)
    case fallback(String)
  }

  private static let defaultGitExecutableURLs = [
    URL(filePath: "/Applications/Xcode.app/Contents/Developer/usr/bin/git"),
    URL(filePath: "/Library/Developer/CommandLineTools/usr/bin/git"),
    URL(filePath: "/opt/homebrew/bin/git"),
    URL(filePath: "/usr/local/bin/git"),
    URL(filePath: "/opt/local/bin/git"),
    URL(filePath: "/usr/bin/git"),
  ]

  private let excludedNames: Set<String>
  private let gitExecutableURL: URL?
  private let gitEnvironment: [String: String]
  private let processRunner: any CommandProcessRunning
  private let gitTimeoutSeconds: Int
  private let maxGitOutputBytes: Int

  package init(
    excludedNames: Set<String> = WorkspaceFileDiscovery.excludedNames,
    gitExecutableURL: URL? = WorkspaceFileDiscovery.defaultGitExecutableURL(),
    gitEnvironment: [String: String] = ProcessInfo.processInfo.environment,
    processRunner: any CommandProcessRunning = DefaultCommandProcessRunner(),
    gitTimeoutSeconds: Int = 5,
    maxGitOutputBytes: Int = 2 * 1024 * 1024
  ) {
    self.excludedNames = excludedNames
    self.gitExecutableURL = gitExecutableURL
    self.gitEnvironment = gitEnvironment
    self.processRunner = processRunner
    self.gitTimeoutSeconds = gitTimeoutSeconds
    self.maxGitOutputBytes = maxGitOutputBytes
  }

  package func visitRecursiveFiles(
    at rootURL: URL,
    relativeTo workspaceRootURL: URL,
    visit: (DiscoveredFile) throws -> Bool
  ) async throws -> Bool {
    guard !isExcludedRoot(rootURL, workspaceRootURL: workspaceRootURL) else {
      return false
    }

    switch try await repositoryState(at: rootURL) {
    case .fallback(let reason):
      WorkspaceDiscoveryDiagnostics.recordFallback(reason)
      return try !visitFileManagerFiles(
        at: rootURL,
        workspaceRootURL: workspaceRootURL,
        visit: visit
      )
    case .repository:
      switch try await ignoredPaths(["."], at: rootURL, quiet: true) {
      case .fallback(let reason):
        WorkspaceDiscoveryDiagnostics.recordFallback(reason)
        return try !visitFileManagerFiles(
          at: rootURL,
          workspaceRootURL: workspaceRootURL,
          visit: visit
        )
      case .ignored(let paths) where paths.contains("."):
        // The selected discovery root is an explicit user scope. Ignore rules may hide its
        // contents during implicit discovery, but must not make an explicit scope unusable.
        return try !visitFileManagerFiles(
          at: rootURL,
          workspaceRootURL: workspaceRootURL,
          visit: visit
        )
      case .ignored:
        break
      }
    }

    let result: CommandProcessResult
    do {
      result = try await runGit(
        [
          "ls-files", "--cached", "--others", "--exclude-standard", "--deduplicate", "-z", "--",
          ".",
        ],
        at: rootURL,
        maxStdoutBytes: maxGitOutputBytes
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw WorkspaceFileDiscoveryError.gitFailed(error.localizedDescription)
    }

    try validateRecognizedRepositoryResult(result, command: "git ls-files")
    if result.exitCode != 0, isGitUnavailableOutput(result) {
      WorkspaceDiscoveryDiagnostics.recordFallback("Git repository metadata is unavailable.")
      return try !visitFileManagerFiles(
        at: rootURL,
        workspaceRootURL: workspaceRootURL,
        visit: visit
      )
    }
    guard result.exitCode == 0 else {
      throw WorkspaceFileDiscoveryError.gitFailed(failureMessage(for: result))
    }

    let paths = nulTerminatedPaths(from: result.stdoutData, truncated: result.stdoutTruncated)
    var files: [DiscoveredFile] = []
    var seenPaths = Set<String>()
    for path in paths {
      try Task.checkCancellation()
      guard
        let file = try validatedFile(
          pathFromRoot: path,
          rootURL: rootURL,
          workspaceRootURL: workspaceRootURL
        ), seenPaths.insert(file.relativePath).inserted
      else {
        continue
      }
      files.append(file)
    }

    for file in naturallySorted(files, path: \.relativePath) {
      guard try visit(file) else {
        return true
      }
    }
    return result.stdoutTruncated
  }

  package func directChildren(
    at rootURL: URL,
    relativeTo workspaceRootURL: URL
  ) async throws -> [DiscoveredEntry] {
    guard !isExcludedRoot(rootURL, workspaceRootURL: workspaceRootURL) else {
      return []
    }

    var entries = try physicalChildren(at: rootURL, workspaceRootURL: workspaceRootURL)
    guard !entries.isEmpty else {
      return []
    }

    switch try await repositoryState(at: rootURL) {
    case .fallback(let reason):
      WorkspaceDiscoveryDiagnostics.recordFallback(reason)
    case .repository:
      switch try await ignoredPaths(["."], at: rootURL, quiet: true) {
      case .fallback(let reason):
        WorkspaceDiscoveryDiagnostics.recordFallback(reason)
      case .ignored(let paths) where paths.contains("."):
        break
      case .ignored:
        let names = entries.map(\.url.lastPathComponent)
        switch try await ignoredPaths(names, at: rootURL) {
        case .fallback(let reason):
          WorkspaceDiscoveryDiagnostics.recordFallback(reason)
        case .ignored(let ignoredNames):
          entries.removeAll { ignoredNames.contains($0.url.lastPathComponent) }
        }
      }
    }

    return naturallySorted(entries, path: \.relativePath)
  }

  package static func defaultGitExecutableURL() -> URL? {
    defaultGitExecutableURLs.first { url in
      FileManager.default.isExecutableFile(atPath: url.path(percentEncoded: false))
    }
  }

  private func repositoryState(at rootURL: URL) async throws -> RepositoryState {
    guard gitExecutableURL != nil else {
      return .fallback("Git executable is unavailable.")
    }

    let result: CommandProcessResult
    do {
      result = try await runGit(
        ["rev-parse", "--is-inside-work-tree"],
        at: rootURL,
        maxStdoutBytes: 4 * 1024
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return .fallback("Git could not be launched: \(error.localizedDescription)")
    }
    if result.cancelled {
      throw CancellationError()
    }
    if result.timedOut {
      throw WorkspaceFileDiscoveryError.gitTimedOut("git rev-parse")
    }
    if result.exitCode == 0,
      result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    {
      return .repository
    }
    if isNotGitRepositoryOutput(result) {
      return .fallback("Workspace is not inside a Git repository.")
    }
    if isGitUnavailableOutput(result) {
      return .fallback("Git repository metadata is unavailable.")
    }
    throw WorkspaceFileDiscoveryError.gitFailed(failureMessage(for: result))
  }

  private func ignoredPaths(
    _ paths: [String],
    at rootURL: URL,
    quiet: Bool = false
  ) async throws -> IgnoreCheck {
    var ignored = Set<String>()
    for batch in paths.chunked(maxCount: 128) {
      let arguments =
        quiet ? ["check-ignore", "-q", "--"] + batch : ["check-ignore", "-z", "--stdin"]
      let standardInput =
        quiet ? nil : (batch.joined(separator: "\0") + "\0").data(using: .utf8)
      let result: CommandProcessResult
      do {
        result = try await runGit(
          arguments,
          at: rootURL,
          maxStdoutBytes: quiet ? 4 * 1024 : 64 * 1024,
          standardInput: standardInput
        )
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw WorkspaceFileDiscoveryError.gitFailed(error.localizedDescription)
      }

      if result.cancelled {
        throw CancellationError()
      }
      if result.timedOut {
        throw WorkspaceFileDiscoveryError.gitTimedOut("git check-ignore")
      }
      if result.exitCode == 1 {
        continue
      }
      if result.exitCode != 0, isGitUnavailableOutput(result) {
        return .fallback("Git repository metadata is unavailable.")
      }
      guard result.exitCode == 0 else {
        throw WorkspaceFileDiscoveryError.gitFailed(failureMessage(for: result))
      }
      guard !result.stdoutTruncated else {
        throw WorkspaceFileDiscoveryError.gitFailed("git check-ignore output exceeded its limit.")
      }

      if quiet {
        ignored.formUnion(batch)
      } else {
        ignored.formUnion(nulTerminatedPaths(from: result.stdoutData, truncated: false))
      }
    }
    return .ignored(ignored)
  }

  private func runGit(
    _ arguments: [String],
    at rootURL: URL,
    maxStdoutBytes: Int,
    standardInput: Data? = nil
  ) async throws -> CommandProcessResult {
    guard let gitExecutableURL else {
      throw WorkspaceFileDiscoveryError.gitUnavailable
    }
    var environment = gitEnvironment
    environment["GIT_OPTIONAL_LOCKS"] = "0"
    return try await processRunner.run(
      CommandProcessRequest(
        executableURL: gitExecutableURL,
        arguments: ["-c", "core.fsmonitor=false", "-C", rootURL.path(percentEncoded: false)]
          + arguments,
        environment: environment,
        workingDirectoryURL: rootURL,
        timeoutSeconds: gitTimeoutSeconds,
        standardInput: standardInput,
        maxStdoutBytes: maxStdoutBytes,
        maxStderrBytes: 64 * 1024
      )
    )
  }

  private func validateRecognizedRepositoryResult(
    _ result: CommandProcessResult,
    command: String
  ) throws {
    if result.cancelled {
      throw CancellationError()
    }
    if result.timedOut {
      throw WorkspaceFileDiscoveryError.gitTimedOut(command)
    }
  }

  private func visitFileManagerFiles(
    at directoryURL: URL,
    workspaceRootURL: URL,
    visit: (DiscoveredFile) throws -> Bool
  ) throws -> Bool {
    try Task.checkCancellation()
    let children = try FileManager.default.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
      ],
      options: [.skipsPackageDescendants]
    )
    .sorted { lhs, rhs in
      lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
    }

    for child in children {
      let relativePath = lexicalRelativePath(for: child, rootURL: workspaceRootURL)
      guard isValidRelativePath(relativePath), !containsExcludedName(relativePath) else {
        continue
      }

      let values = try child.resourceValues(
        forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
      if values.isSymbolicLink == true {
        if let file = try validatedFile(
          pathFromRoot: lexicalRelativePath(for: child, rootURL: directoryURL),
          rootURL: directoryURL,
          workspaceRootURL: workspaceRootURL
        ) {
          guard try visit(file) else {
            return false
          }
        }
      } else if values.isDirectory == true {
        guard
          try visitFileManagerFiles(
            at: child,
            workspaceRootURL: workspaceRootURL,
            visit: visit
          )
        else {
          return false
        }
      } else if values.isRegularFile == true {
        guard try visit(DiscoveredFile(url: child, relativePath: relativePath)) else {
          return false
        }
      }
    }
    return true
  }

  private func physicalChildren(
    at rootURL: URL,
    workspaceRootURL: URL
  ) throws -> [DiscoveredEntry] {
    let children = try FileManager.default.contentsOfDirectory(
      at: rootURL,
      includingPropertiesForKeys: [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
      ],
      options: []
    )
    var entries: [DiscoveredEntry] = []
    for child in children {
      let relativePath = lexicalRelativePath(for: child, rootURL: workspaceRootURL)
      guard isValidRelativePath(relativePath), !containsExcludedName(relativePath) else {
        continue
      }

      let values = try child.resourceValues(
        forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
      if values.isSymbolicLink == true {
        let targetURL = child.resolvingSymlinksInPath()
        guard isContained(targetURL, in: workspaceRootURL) else {
          continue
        }
        let targetValues = try targetURL.resourceValues(
          forKeys: [.isDirectoryKey, .isRegularFileKey])
        if targetValues.isDirectory == true {
          entries.append(
            DiscoveredEntry(url: child, relativePath: relativePath, kind: .directory))
        } else if targetValues.isRegularFile == true {
          entries.append(DiscoveredEntry(url: child, relativePath: relativePath, kind: .file))
        }
      } else if values.isDirectory == true {
        entries.append(DiscoveredEntry(url: child, relativePath: relativePath, kind: .directory))
      } else if values.isRegularFile == true {
        entries.append(DiscoveredEntry(url: child, relativePath: relativePath, kind: .file))
      }
    }
    return entries
  }

  private func validatedFile(
    pathFromRoot: String,
    rootURL: URL,
    workspaceRootURL: URL
  ) throws -> DiscoveredFile? {
    guard isValidRelativePath(pathFromRoot) else {
      return nil
    }
    let candidateURL = rootURL.appending(path: pathFromRoot).standardizedFileURL
    let relativePath = lexicalRelativePath(for: candidateURL, rootURL: workspaceRootURL)
    guard isValidRelativePath(relativePath), !containsExcludedName(relativePath) else {
      return nil
    }

    let values: URLResourceValues
    do {
      values = try candidateURL.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    } catch let error as NSError
      where error.domain == NSCocoaErrorDomain
      && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError)
    {
      return nil
    }

    if values.isSymbolicLink == true {
      let targetURL = candidateURL.resolvingSymlinksInPath()
      guard isContained(targetURL, in: workspaceRootURL) else {
        return nil
      }
      let targetValues = try targetURL.resourceValues(forKeys: [.isRegularFileKey])
      guard targetValues.isRegularFile == true else {
        return nil
      }
    } else {
      guard values.isRegularFile == true else {
        return nil
      }
    }

    return DiscoveredFile(url: candidateURL, relativePath: relativePath)
  }

  private func isExcludedRoot(_ rootURL: URL, workspaceRootURL: URL) -> Bool {
    let relativePath = lexicalRelativePath(for: rootURL, rootURL: workspaceRootURL)
    return relativePath != "." && containsExcludedName(relativePath)
  }

  private func containsExcludedName(_ relativePath: String) -> Bool {
    relativePath.split(separator: "/").contains { excludedNames.contains(String($0)) }
  }

  private func isValidRelativePath(_ path: String) -> Bool {
    guard !path.isEmpty, path != ".", !path.hasPrefix("/") else {
      return false
    }
    return !path.split(separator: "/", omittingEmptySubsequences: false).contains { component in
      component.isEmpty || component == "." || component == ".."
    }
  }

  private func lexicalRelativePath(for url: URL, rootURL: URL) -> String {
    let rootPath = removingTrailingSlashes(
      from: rootURL.standardizedFileURL.path(percentEncoded: false))
    let candidatePath = removingTrailingSlashes(
      from: url.standardizedFileURL.path(percentEncoded: false))
    if candidatePath == rootPath {
      return "."
    }
    guard candidatePath.hasPrefix(rootPath + "/") else {
      return candidatePath
    }
    return String(candidatePath.dropFirst(rootPath.count + 1))
  }

  private func removingTrailingSlashes(from path: String) -> String {
    var path = path
    while path.count > 1, path.hasSuffix("/") {
      path.removeLast()
    }
    return path
  }

  private func isContained(_ url: URL, in workspaceRootURL: URL) -> Bool {
    let rootPath = workspaceRootURL.resolvingSymlinksInPath().standardizedFileURL
      .path(percentEncoded: false)
    let candidatePath = url.resolvingSymlinksInPath().standardizedFileURL
      .path(percentEncoded: false)
    return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
  }

  private func nulTerminatedPaths(from output: Data, truncated: Bool) -> [String] {
    var paths: [String] = []
    var recordStart = output.startIndex

    for index in output.indices where output[index] == 0 {
      let record = output[recordStart..<index]
      if !record.isEmpty, let path = String(data: record, encoding: .utf8) {
        paths.append(path)
      }
      recordStart = output.index(after: index)
    }

    if !truncated, recordStart < output.endIndex {
      let record = output[recordStart..<output.endIndex]
      if let path = String(data: record, encoding: .utf8) {
        paths.append(path)
      }
    }
    return paths
  }

  private func naturallySorted<Value>(
    _ values: [Value],
    path: KeyPath<Value, String>
  ) -> [Value] {
    values.sorted { lhs, rhs in
      let lhsPath = lhs[keyPath: path]
      let rhsPath = rhs[keyPath: path]
      let comparison = lhsPath.localizedStandardCompare(rhsPath)
      return comparison == .orderedSame ? lhsPath < rhsPath : comparison == .orderedAscending
    }
  }

  private func isNotGitRepositoryOutput(_ result: CommandProcessResult) -> Bool {
    combinedOutput(result).localizedCaseInsensitiveContains("not a git repository")
  }

  private func isGitUnavailableOutput(_ result: CommandProcessResult) -> Bool {
    let output = combinedOutput(result)
    return output.localizedCaseInsensitiveContains("operation not permitted")
      || output.localizedCaseInsensitiveContains("permission denied")
      || output.localizedCaseInsensitiveContains("cannot be used within an App Sandbox")
  }

  private func combinedOutput(_ result: CommandProcessResult) -> String {
    result.stderr.isEmpty ? result.stdout : result.stderr
  }

  private func failureMessage(for result: CommandProcessResult) -> String {
    let output = combinedOutput(result).trimmingCharacters(in: .whitespacesAndNewlines)
    let status = result.exitCode.map(String.init) ?? "unknown"
    return output.isEmpty ? "Git exited with status \(status)." : output
  }
}

private enum WorkspaceFileDiscoveryError: LocalizedError {
  case gitUnavailable
  case gitTimedOut(String)
  case gitFailed(String)

  var errorDescription: String? {
    switch self {
    case .gitUnavailable:
      "Git is unavailable for workspace discovery."
    case .gitTimedOut(let command):
      "\(command) timed out while discovering workspace files."
    case .gitFailed(let message):
      "Git workspace discovery failed: \(message)"
    }
  }
}

private enum WorkspaceDiscoveryDiagnostics {
  #if canImport(OSLog)
    private static let logger = Logger(
      subsystem: SumikaTelemetry.subsystem,
      category: "WorkspaceDiscovery"
    )
  #endif

  static func recordFallback(_ reason: String) {
    #if canImport(OSLog)
      logger.debug("Using FileManager workspace discovery fallback: \(reason, privacy: .public)")
    #endif
  }
}

extension Array {
  fileprivate func chunked(maxCount: Int) -> [[Element]] {
    guard maxCount > 0, !isEmpty else {
      return []
    }
    return stride(from: 0, to: count, by: maxCount).map { start in
      Array(self[start..<Swift.min(start + maxCount, count)])
    }
  }
}

internal struct GlobPatternMatcher {
  private let regex: NSRegularExpression

  package init(pattern: String) throws {
    regex = try NSRegularExpression(pattern: Self.regularExpressionPattern(for: pattern))
  }

  package func matches(_ value: String) -> Bool {
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    return regex.firstMatch(in: value, range: range) != nil
  }

  private static func regularExpressionPattern(for pattern: String) -> String {
    var output = "^"
    var index = pattern.startIndex

    while index < pattern.endIndex {
      let character = pattern[index]
      let nextIndex = pattern.index(after: index)

      if character == "*" {
        if nextIndex < pattern.endIndex, pattern[nextIndex] == "*" {
          let afterGlobstar = pattern.index(after: nextIndex)
          if afterGlobstar < pattern.endIndex, pattern[afterGlobstar] == "/" {
            output += "(?:.*/)?"
            index = pattern.index(after: afterGlobstar)
          } else {
            output += ".*"
            index = afterGlobstar
          }
        } else {
          output += "[^/]*"
          index = nextIndex
        }
      } else if character == "?" {
        output += "[^/]"
        index = nextIndex
      } else {
        output += NSRegularExpression.escapedPattern(for: String(character))
        index = nextIndex
      }
    }

    return output + "$"
  }
}

internal struct SearchPattern {
  private let regex: NSRegularExpression?
  private let literal: String

  package init(pattern: String) {
    regex = try? NSRegularExpression(pattern: pattern)
    literal = pattern
  }

  func firstMatchRange(in line: String) -> Range<String.Index>? {
    if let regex {
      guard
        let match = regex.firstMatch(
          in: line,
          range: NSRange(line.startIndex..<line.endIndex, in: line)
        )
      else {
        return nil
      }
      return Range(match.range, in: line)
    }

    return line.range(of: literal)
  }

  package func matches(_ line: String) -> Bool {
    if let regex {
      return regex.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line))
        != nil
    }

    return line.contains(literal)
  }
}
