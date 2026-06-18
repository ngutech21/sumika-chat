import Foundation

public struct RunCommandInput: Codable, Equatable, Sendable {
  public static let defaultTimeoutSeconds = 120

  public let command: String
  public let timeoutSeconds: Int
  public let reason: String?

  private enum CodingKeys: String, CodingKey {
    case command
    case timeoutSeconds
    case reason
  }

  public init(command: String, timeoutSeconds: Int, reason: String? = nil) {
    self.command = command
    self.timeoutSeconds = timeoutSeconds
    self.reason = reason
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    command = try container.decode(String.self, forKey: .command)
    if let value = try? container.decode(Int.self, forKey: .timeoutSeconds) {
      timeoutSeconds = value
    } else if let stringValue = try? container.decode(String.self, forKey: .timeoutSeconds),
      let value = Int(stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    {
      timeoutSeconds = value
    } else if !container.contains(.timeoutSeconds) {
      timeoutSeconds = Self.defaultTimeoutSeconds
    } else {
      throw RunCommandInputValidationError.invalidTimeout
    }
    reason = try container.decodeIfPresent(String.self, forKey: .reason)
  }
}

public enum RunCommandInputValidationError: LocalizedError, Equatable {
  case invalidTimeout

  public var errorDescription: String? {
    switch self {
    case .invalidTimeout:
      "run_command timeoutSeconds must be an integer."
    }
  }
}

public actor LatestCommandResultStore {
  public static let defaultMaxOutputRefsPerSession = 4
  public static let defaultMaxOutputBytesPerSession = 2 * 1024 * 1024

  private struct Key: Hashable, Sendable {
    var workspaceID: Workspace.ID
    var sessionID: ChatSession.ID
  }

  private let maxOutputRefsPerSession: Int
  private let maxOutputBytesPerSession: Int
  private var results: [Key: RunCommandResult] = [:]
  private var outputs: [Key: [String: CommandOutputRecord]] = [:]
  private var outputOrder: [Key: [String]] = [:]

  public init(
    maxOutputRefsPerSession: Int = LatestCommandResultStore.defaultMaxOutputRefsPerSession,
    maxOutputBytesPerSession: Int = LatestCommandResultStore.defaultMaxOutputBytesPerSession
  ) {
    self.maxOutputRefsPerSession = max(maxOutputRefsPerSession, 1)
    self.maxOutputBytesPerSession = max(maxOutputBytesPerSession, 1)
  }

  public func result(workspaceID: Workspace.ID, sessionID: ChatSession.ID) -> RunCommandResult? {
    results[Key(workspaceID: workspaceID, sessionID: sessionID)]
  }

  public func record(
    _ result: RunCommandResult,
    workspaceID: Workspace.ID,
    sessionID: ChatSession.ID
  ) {
    results[Key(workspaceID: workspaceID, sessionID: sessionID)] = result
  }

  public func record(
    _ result: RunCommandResult,
    output: CommandOutputRecord,
    workspaceID: Workspace.ID,
    sessionID: ChatSession.ID
  ) {
    let key = Key(workspaceID: workspaceID, sessionID: sessionID)
    results[key] = result
    outputs[key, default: [:]][output.outputRef] = output
    var order = outputOrder[key, default: []].filter { $0 != output.outputRef }
    order.append(output.outputRef)
    outputOrder[key] = order
    pruneOutputs(for: key)
  }

  public func output(
    outputRef: String,
    workspaceID: Workspace.ID,
    sessionID: ChatSession.ID
  ) -> CommandOutputRecord? {
    outputs[Key(workspaceID: workspaceID, sessionID: sessionID)]?[outputRef]
  }

  private func pruneOutputs(for key: Key) {
    guard var order = outputOrder[key], var records = outputs[key] else {
      return
    }

    var totalBytes = order.reduce(0) { partialResult, outputRef in
      partialResult + (records[outputRef]?.byteCount ?? 0)
    }

    while order.count > maxOutputRefsPerSession || totalBytes > maxOutputBytesPerSession {
      guard let removedRef = order.first else {
        break
      }
      order.removeFirst()
      if let removedRecord = records.removeValue(forKey: removedRef) {
        totalBytes -= removedRecord.byteCount
      }
    }

    outputs[key] = records
    outputOrder[key] = order
  }
}

public struct CommandOutputRecord: Equatable, Sendable {
  public var outputRef: String
  public var stdout: String
  public var stderr: String

  public init(outputRef: String, stdout: String, stderr: String) {
    self.outputRef = outputRef
    self.stdout = stdout
    self.stderr = stderr
  }

  public var byteCount: Int {
    outputRef.utf8.count + stdout.utf8.count + stderr.utf8.count
  }
}

public struct WorkspaceDiagnosticsToolExecutor: TypedToolExecutor {
  public static let definition = ToolDefinition.workspaceDiagnostics

  public init() {}

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

public struct CommandProcessRequest: Equatable, Sendable {
  public var executableURL: URL
  public var arguments: [String]
  public var environment: [String: String]
  public var workingDirectoryURL: URL
  public var timeoutSeconds: Int

  public init(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    workingDirectoryURL: URL,
    timeoutSeconds: Int
  ) {
    self.executableURL = executableURL
    self.arguments = arguments
    self.environment = environment
    self.workingDirectoryURL = workingDirectoryURL
    self.timeoutSeconds = timeoutSeconds
  }
}

public struct CommandProcessResult: Equatable, Sendable {
  public var exitCode: Int32?
  public var durationMs: Int
  public var stdout: String
  public var stderr: String
  public var timedOut: Bool
  public var cancelled: Bool

  public init(
    exitCode: Int32?,
    durationMs: Int,
    stdout: String,
    stderr: String,
    timedOut: Bool = false,
    cancelled: Bool = false
  ) {
    self.exitCode = exitCode
    self.durationMs = durationMs
    self.stdout = stdout
    self.stderr = stderr
    self.timedOut = timedOut
    self.cancelled = cancelled
  }
}

public protocol CommandProcessRunning: Sendable {
  func run(_ request: CommandProcessRequest) async throws -> CommandProcessResult
}

private enum CommandProcessWaitOutcome: Sendable {
  case exited
  case timedOut
  case cancelled
}

private final class ProcessTerminationSignal: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Never>?
  private var didTerminate = false

  func signal() {
    let continuationToResume: CheckedContinuation<Void, Never>?
    lock.lock()
    didTerminate = true
    continuationToResume = continuation
    continuation = nil
    lock.unlock()

    continuationToResume?.resume()
  }

  func wait() async {
    await withCheckedContinuation { continuation in
      let continuationToResume: CheckedContinuation<Void, Never>?
      lock.lock()
      if didTerminate {
        continuationToResume = continuation
      } else {
        self.continuation = continuation
        continuationToResume = nil
      }
      lock.unlock()

      continuationToResume?.resume()
    }
  }
}

public actor DefaultCommandProcessRunner: CommandProcessRunning {
  private var runningProcesses: [UUID: Process] = [:]

  public init() {}

  public func run(_ request: CommandProcessRequest) async throws -> CommandProcessResult {
    let id = UUID()
    return try await withTaskCancellationHandler {
      try await runProcess(id: id, request: request)
    } onCancel: {
      Task {
        await self.terminateProcess(id: id)
      }
    }
  }

  private func runProcess(
    id: UUID,
    request: CommandProcessRequest
  ) async throws -> CommandProcessResult {
    let process = Process()
    process.executableURL = request.executableURL
    process.arguments = request.arguments
    process.environment = request.environment
    process.currentDirectoryURL = request.workingDirectoryURL

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    let startedAt = Date()
    let terminationSignal = ProcessTerminationSignal()
    process.terminationHandler = { _ in
      terminationSignal.signal()
    }
    runningProcesses[id] = process
    defer {
      process.terminationHandler = nil
      runningProcesses[id] = nil
    }

    try process.run()

    let stdoutTask = Task {
      try stdoutPipe.fileHandleForReading.readToEnd() ?? Data()
    }
    let stderrTask = Task {
      try stderrPipe.fileHandleForReading.readToEnd() ?? Data()
    }

    let waitOutcome = await waitForExitOrTimeout(
      process: process,
      terminationSignal: terminationSignal,
      timeoutSeconds: request.timeoutSeconds
    )

    process.waitUntilExit()
    let durationMs = max(Int(Date().timeIntervalSince(startedAt) * 1000), 0)
    let stdoutData = try await stdoutTask.value
    let stderrData = try await stderrTask.value

    return CommandProcessResult(
      exitCode: process.terminationStatus,
      durationMs: durationMs,
      stdout: String(data: stdoutData, encoding: .utf8) ?? "",
      stderr: String(data: stderrData, encoding: .utf8) ?? "",
      timedOut: waitOutcome == .timedOut,
      cancelled: waitOutcome == .cancelled
    )
  }

  private func waitForExitOrTimeout(
    process: Process,
    terminationSignal: ProcessTerminationSignal,
    timeoutSeconds: Int
  ) async -> CommandProcessWaitOutcome {
    do {
      return try await withThrowingTaskGroup(of: CommandProcessWaitOutcome.self) { group in
        group.addTask {
          await terminationSignal.wait()
          return .exited
        }

        group.addTask {
          do {
            try await Task.sleep(for: .seconds(timeoutSeconds))
            return Task.isCancelled ? .cancelled : .timedOut
          } catch {
            return .cancelled
          }
        }

        let outcome = try await group.next() ?? .exited
        if outcome != .exited, process.isRunning {
          terminateProcessTree(process)
        }
        group.cancelAll()
        return outcome
      }
    } catch {
      if process.isRunning {
        terminateProcessTree(process)
      }
      await terminationSignal.wait()
      return .cancelled
    }
  }

  private func terminateProcess(id: UUID) {
    guard let process = runningProcesses[id], process.isRunning else {
      return
    }
    terminateProcessTree(process)
  }
}

private func terminateProcessTree(_ process: Process) {
  let rootPID = process.processIdentifier
  let descendantPIDs = processDescendantIDs(of: rootPID)
  terminateProcesses(descendantPIDs.reversed())

  if process.isRunning {
    process.terminate()
  }
}

private func processDescendantIDs(of rootPID: Int32) -> [Int32] {
  let processParents = processParentIDs()
  var descendants: [Int32] = []
  var pending = [rootPID]

  while let parent = pending.popLast() {
    let children = processParents.compactMap { pid, parentPID in
      parentPID == parent ? pid : nil
    }
    descendants.append(contentsOf: children)
    pending.append(contentsOf: children)
  }

  return descendants
}

private func processParentIDs() -> [Int32: Int32] {
  guard
    let psURL = firstExecutableURL(paths: ["/bin/ps", "/usr/bin/ps"]),
    let output = runTerminationHelper(psURL, arguments: ["-axo", "pid=,ppid="])
  else {
    return [:]
  }

  var parents: [Int32: Int32] = [:]
  for line in output.split(whereSeparator: \.isNewline) {
    let fields = line.split(whereSeparator: \.isWhitespace)
    guard fields.count >= 2, let pid = Int32(fields[0]), let parentPID = Int32(fields[1]) else {
      continue
    }
    parents[pid] = parentPID
  }
  return parents
}

private func terminateProcesses(_ processIDs: [Int32]) {
  guard
    !processIDs.isEmpty,
    let killURL = firstExecutableURL(paths: ["/bin/kill", "/usr/bin/kill"])
  else {
    return
  }

  _ = runTerminationHelper(
    killURL,
    arguments: ["-TERM"] + processIDs.map(String.init)
  )
}

private func runTerminationHelper(_ executableURL: URL, arguments: [String]) -> String? {
  let process = Process()
  process.executableURL = executableURL
  process.arguments = arguments

  let outputPipe = Pipe()
  process.standardOutput = outputPipe
  process.standardError = Pipe()

  do {
    try process.run()
    process.waitUntilExit()
    let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: output, encoding: .utf8)
  } catch {
    return nil
  }
}

private func firstExecutableURL(paths: [String]) -> URL? {
  for path in paths where FileManager.default.isExecutableFile(atPath: path) {
    return URL(filePath: path)
  }
  return nil
}

public struct RunCommandToolExecutor: TypedToolExecutor {
  public static let definition = ToolDefinition.runCommand

  public static let minimumTimeoutSeconds = 1
  public static let maximumTimeoutSeconds = 120

  private let bashExecutableURL: URL
  private let environment: [String: String]
  private let pathPrefixDirectories: [URL]
  private let maxOutputBytes: Int
  private let outputRefGenerator: @Sendable () -> String
  private let processRunner: any CommandProcessRunning

  public init(
    bashExecutableURL: URL = URL(filePath: "/bin/bash"),
    environment: [String: String] = ProcessInfo.processInfo.environment,
    pathPrefixDirectories: [URL] = [
      URL(filePath: "/opt/homebrew/bin"),
      URL(filePath: "/usr/local/bin"),
      URL(filePath: "/opt/local/bin"),
    ],
    maxOutputBytes: Int = 48 * 1024,
    outputRefGenerator: @escaping @Sendable () -> String = {
      let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
      return "cmd_" + String(id)
    },
    processRunner: any CommandProcessRunning = DefaultCommandProcessRunner()
  ) {
    self.bashExecutableURL = bashExecutableURL
    self.environment = environment
    self.pathPrefixDirectories = pathPrefixDirectories
    self.maxOutputBytes = maxOutputBytes
    self.outputRefGenerator = outputRefGenerator
    self.processRunner = processRunner
  }

  public func evaluatePermission(
    _ input: RunCommandInput,
    context: ToolContext
  ) -> ToolPermissionEvaluation {
    do {
      let workspaceRoot = try context.workspace.resolveAllowedPath(".")
      return ToolPermissionEvaluation(
        decision: .requiresApproval,
        reason: "Running commands inside the workspace requires approval.",
        riskLevel: .high,
        normalizedPaths: [workspaceRoot.path(percentEncoded: false)],
        workspaceRelativePaths: [WorkspaceRelativePath(rawValue: ".")]
      )
    } catch {
      return ToolPermissionEvaluation(
        decision: .denied,
        reason: error.localizedDescription,
        riskLevel: .high
      )
    }
  }

  public func previewApproval(
    _ input: RunCommandInput,
    context: ToolContext
  ) async -> ToolResultPreview? {
    ToolResultPreview(
      text: [
        "Command requires approval.",
        "Workspace: \(context.workspace.normalizedRootPath)",
        "Timeout: \(clampedTimeout(input.timeoutSeconds)) seconds",
        input.reason.map { "Reason: \($0)" },
        "Command:\n\(input.command)",
      ].compactMap(\.self).joined(separator: "\n"),
      affectedPaths: ["."]
    )
  }

  public func run(_ input: RunCommandInput, context: ToolContext) async -> ToolResultPayload {
    do {
      return try await context.workspace.withSecurityScopedAccess {
        let workspaceRoot = try context.workspace.resolveAllowedPath(".")
        let timeoutSeconds = clampedTimeout(input.timeoutSeconds)
        let request = CommandProcessRequest(
          executableURL: bashExecutableURL,
          arguments: ["-c", input.command],
          environment: commandEnvironment(workspaceRoot: workspaceRoot),
          workingDirectoryURL: workspaceRoot,
          timeoutSeconds: timeoutSeconds
        )
        let processResult = try await processRunner.run(request)
        let outputRef = outputRefGenerator()
        let limits = previewLimits(exitCode: processResult.exitCode)
        let stdoutPreview = previewOutput(
          processResult.stdout,
          maxBytes: min(limits.stdoutBytes, maxOutputBytes)
        )
        let stderrPreview = previewOutput(
          processResult.stderr,
          maxBytes: min(limits.stderrBytes, maxOutputBytes)
        )
        let result = RunCommandResult(
          command: input.command,
          timeoutSeconds: timeoutSeconds,
          exitCode: processResult.exitCode,
          durationMs: processResult.durationMs,
          stdout: stdoutPreview.output,
          stderr: stderrPreview.output,
          outputRef: outputRef,
          stdoutOmittedChars: stdoutPreview.omittedChars,
          stderrOmittedChars: stderrPreview.omittedChars,
          timedOut: processResult.timedOut,
          cancelled: processResult.cancelled
        )
        if let sessionID = context.sessionID {
          await context.latestCommandResultStore?.record(
            result,
            output: CommandOutputRecord(
              outputRef: outputRef,
              stdout: processResult.stdout,
              stderr: processResult.stderr
            ),
            workspaceID: context.workspace.id,
            sessionID: sessionID
          )
        }
        return .runCommand(result)
      }
    } catch {
      return .failure(
        ToolFailure(
          toolName: .runCommand,
          path: WorkspaceRelativePath(rawValue: "."),
          reason: ToolResultFailureMapper.reason(from: error)
        )
      )
    }
  }

  private func commandEnvironment(workspaceRoot: URL) -> [String: String] {
    var resolved = environment
    resolved["PWD"] = workspaceRoot.path(percentEncoded: false)

    let existingPath = resolved["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    let prefix =
      pathPrefixDirectories
      .map { $0.path(percentEncoded: false) }
      .joined(separator: ":")
    resolved["PATH"] = prefix.isEmpty ? existingPath : prefix + ":" + existingPath
    return resolved
  }

  private func clampedTimeout(_ timeoutSeconds: Int) -> Int {
    min(max(timeoutSeconds, Self.minimumTimeoutSeconds), Self.maximumTimeoutSeconds)
  }

  private func previewLimits(exitCode: Int32?) -> (stdoutBytes: Int, stderrBytes: Int) {
    if exitCode == 0 {
      return (stdoutBytes: 8 * 1024, stderrBytes: 4 * 1024)
    }
    return (stdoutBytes: 16 * 1024, stderrBytes: 16 * 1024)
  }

  private func previewOutput(_ text: String, maxBytes: Int) -> (
    output: ToolTextOutput, omittedChars: Int
  ) {
    guard text.utf8.count > maxBytes else {
      return (ToolTextOutput(text: text), 0)
    }

    let placeholder = "\n... truncated 0 chars ...\n"
    let availableBytes = max(maxBytes - placeholder.utf8.count, 0)
    let headBytes = Int(Double(availableBytes) * 0.4)
    let tailBytes = max(availableBytes - headBytes, 0)
    let head = utf8StringDroppingPartialSuffix(from: Data(text.utf8.prefix(headBytes)))
    let tail = utf8StringDroppingPartialPrefix(from: Data(text.utf8.suffix(tailBytes)))
    let omittedChars = max(text.count - head.count - tail.count, 0)
    let marker = "\n... truncated \(omittedChars) chars ...\n"
    return (ToolTextOutput(text: head + marker + tail, truncated: true), omittedChars)
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

  private func utf8StringDroppingPartialPrefix(from data: Data) -> String {
    if let string = String(bytes: data, encoding: .utf8) {
      return string
    }

    guard !data.isEmpty else {
      return ""
    }

    for droppedByteCount in 1...min(3, data.count) {
      let shortenedData = data.dropFirst(droppedByteCount)
      if let string = String(bytes: shortenedData, encoding: .utf8) {
        return string
      }
    }

    return ""
  }
}
