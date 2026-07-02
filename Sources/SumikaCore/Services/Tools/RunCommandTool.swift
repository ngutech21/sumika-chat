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

  public static func input(from payload: ToolCallPayload) throws -> RunCommandInput {
    guard case .runCommand(let input) = payload else {
      throw ToolInputDecodingError.payloadMismatch(
        expected: definition.name.rawValue,
        actual: payload.toolName.rawValue
      )
    }
    return input
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
      return try await context.workspace.withAsyncSecurityScopedAccess {
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
