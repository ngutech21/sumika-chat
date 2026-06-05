import Foundation

public struct RunCommandInput: Codable, Equatable, Sendable {
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
  private struct Key: Hashable, Sendable {
    var workspaceID: Workspace.ID
    var sessionID: ChatSession.ID
  }

  private var results: [Key: RunCommandResult] = [:]

  public init() {}

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
    runningProcesses[id] = process
    defer {
      runningProcesses[id] = nil
    }

    try process.run()

    let stdoutTask = Task {
      try stdoutPipe.fileHandleForReading.readToEnd() ?? Data()
    }
    let stderrTask = Task {
      try stderrPipe.fileHandleForReading.readToEnd() ?? Data()
    }

    var timedOut = false
    var cancelled = false
    while process.isRunning {
      if Task.isCancelled {
        cancelled = true
        process.terminate()
        break
      }

      if Date().timeIntervalSince(startedAt) >= TimeInterval(request.timeoutSeconds) {
        timedOut = true
        process.terminate()
        break
      }

      try? await Task.sleep(for: .milliseconds(20))
    }

    process.waitUntilExit()
    let durationMs = max(Int(Date().timeIntervalSince(startedAt) * 1000), 0)
    let stdoutData = try await stdoutTask.value
    let stderrData = try await stderrTask.value

    return CommandProcessResult(
      exitCode: process.terminationStatus,
      durationMs: durationMs,
      stdout: String(data: stdoutData, encoding: .utf8) ?? "",
      stderr: String(data: stderrData, encoding: .utf8) ?? "",
      timedOut: timedOut,
      cancelled: cancelled
    )
  }

  private func terminateProcess(id: UUID) {
    guard let process = runningProcesses[id], process.isRunning else {
      return
    }
    process.terminate()
  }
}

public struct RunCommandToolExecutor: TypedToolExecutor {
  public static let definition = ToolDefinition.runCommand

  public static let minimumTimeoutSeconds = 1
  public static let maximumTimeoutSeconds = 120

  private let bashExecutableURL: URL
  private let environment: [String: String]
  private let pathPrefixDirectories: [URL]
  private let maxOutputBytes: Int
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
    processRunner: any CommandProcessRunning = DefaultCommandProcessRunner()
  ) {
    self.bashExecutableURL = bashExecutableURL
    self.environment = environment
    self.pathPrefixDirectories = pathPrefixDirectories
    self.maxOutputBytes = maxOutputBytes
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
      ].compactMap { $0 }.joined(separator: "\n"),
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
        let result = RunCommandResult(
          command: input.command,
          timeoutSeconds: timeoutSeconds,
          exitCode: processResult.exitCode,
          durationMs: processResult.durationMs,
          stdout: cappedOutput(processResult.stdout, marker: "run_command stdout truncated"),
          stderr: cappedOutput(processResult.stderr, marker: "run_command stderr truncated"),
          timedOut: processResult.timedOut,
          cancelled: processResult.cancelled
        )
        if let sessionID = context.sessionID {
          await context.latestCommandResultStore?.record(
            result,
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

  private func cappedOutput(_ text: String, marker: String) -> ToolTextOutput {
    guard text.utf8.count > maxOutputBytes else {
      return ToolTextOutput(text: text)
    }

    let marker = "\n[\(marker)]"
    let markerBytes = marker.utf8.count
    let prefixByteCount = max(maxOutputBytes - markerBytes, 0)
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
}
