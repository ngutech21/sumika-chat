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

public struct RunCommandResult: Codable, Equatable, Sendable {
  public var command: String
  public var timeoutSeconds: Int
  public var exitCode: Int32?
  public var durationMs: Int
  public var stdout: ToolTextOutput
  public var stderr: ToolTextOutput
  public var outputRef: String?
  public var stdoutOmittedChars: Int
  public var stderrOmittedChars: Int
  public var timedOut: Bool
  public var cancelled: Bool

  private enum CodingKeys: String, CodingKey {
    case command
    case timeoutSeconds
    case exitCode
    case durationMs
    case stdout
    case stderr
    case outputRef
    case stdoutOmittedChars
    case stderrOmittedChars
    case timedOut
    case cancelled
  }

  public init(
    command: String,
    timeoutSeconds: Int,
    exitCode: Int32?,
    durationMs: Int,
    stdout: ToolTextOutput,
    stderr: ToolTextOutput,
    outputRef: String? = nil,
    stdoutOmittedChars: Int = 0,
    stderrOmittedChars: Int = 0,
    timedOut: Bool = false,
    cancelled: Bool = false
  ) {
    self.command = command
    self.timeoutSeconds = timeoutSeconds
    self.exitCode = exitCode
    self.durationMs = durationMs
    self.stdout = stdout
    self.stderr = stderr
    self.outputRef = outputRef
    self.stdoutOmittedChars = stdoutOmittedChars
    self.stderrOmittedChars = stderrOmittedChars
    self.timedOut = timedOut
    self.cancelled = cancelled
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    command = try container.decode(String.self, forKey: .command)
    timeoutSeconds = try container.decode(Int.self, forKey: .timeoutSeconds)
    exitCode = try container.decodeIfPresent(Int32.self, forKey: .exitCode)
    durationMs = try container.decode(Int.self, forKey: .durationMs)
    stdout = try container.decode(ToolTextOutput.self, forKey: .stdout)
    stderr = try container.decode(ToolTextOutput.self, forKey: .stderr)
    outputRef = try container.decodeIfPresent(String.self, forKey: .outputRef)
    stdoutOmittedChars = try container.decodeIfPresent(Int.self, forKey: .stdoutOmittedChars) ?? 0
    stderrOmittedChars = try container.decodeIfPresent(Int.self, forKey: .stderrOmittedChars) ?? 0
    timedOut = try container.decodeIfPresent(Bool.self, forKey: .timedOut) ?? false
    cancelled = try container.decodeIfPresent(Bool.self, forKey: .cancelled) ?? false
  }

  public var outputTruncated: Bool {
    stdout.truncated || stderr.truncated
  }
}

nonisolated extension RunCommandResult {
  var outcomeStatus: ToolResultStatus {
    guard !timedOut, !cancelled, let exitCode, exitCode == 0 else {
      return .failed
    }
    return .success
  }

  var preview: ToolResultPreview {
    ToolResultPreview(
      status: outcomeStatus,
      text: previewText,
      truncated: outputTruncated,
      affectedPaths: ["."]
    )
  }

  public var previewText: String {
    var lines: [String] = [
      "Command: \(command)",
      "Exit code: \(exitCode.map(String.init) ?? "none")",
      "Duration: \(durationMs) ms",
      "Timed out: \(timedOut)",
      "Cancelled: \(cancelled)",
    ]
    if let outputRef {
      lines.append("Output ref: \(outputRef)")
    }
    if outputTruncated {
      lines.append("Output truncated: true")
    }
    if stdoutOmittedChars > 0 {
      lines.append("Stdout omitted chars: \(stdoutOmittedChars)")
    }
    if stderrOmittedChars > 0 {
      lines.append("Stderr omitted chars: \(stderrOmittedChars)")
    }
    if !stdout.text.isEmpty {
      lines.append("stdout:\n\(stdout.text)")
    }
    if !stderr.text.isEmpty {
      lines.append("stderr:\n\(stderr.text)")
    }
    if let outputRef {
      lines.append(
        "Hint: Run workspace_diagnostics(outputRef: \(outputRef)) for structured errors.")
    }
    return lines.joined(separator: "\n")
  }
}

nonisolated extension ToolDefinition {
  public static let runCommand = ToolDefinition(
    name: .runCommand,
    description:
      "Run an approved foreground shell command in the workspace root. Do not use this to write files when write_file or edit_file can do the change.",
    parameters: [
      ToolParameterDefinition(
        name: "command",
        description: "Exact shell command to run.",
        isRequired: true
      ),
      ToolParameterDefinition(
        name: "timeoutSeconds",
        description: "Timeout in seconds. Defaults to 120 when omitted.",
        isRequired: false,
        valueType: .integer,
        defaultValue: .number(120),
        minimum: 1,
        maximum: 120
      ),
      ToolParameterDefinition(
        name: "reason",
        description: "Short reason.",
        isRequired: false
      ),
    ],
    capabilities: [.runCommand],
    riskLevel: .high
  )
}

extension RunCommandInput {
  static func decodeToolArguments(_ arguments: ToolCallArguments) throws -> RunCommandInput {
    do {
      let input = try ToolInputDecoder.decode(RunCommandInput.self, from: arguments)
      try ToolArgumentValidation.requireNonEmptyString(
        input.command,
        name: "command",
        expected: "a non-empty shell command"
      )
      return input
    } catch let error as RunCommandInputValidationError {
      switch error {
      case .invalidTimeout:
        throw InvalidToolCallReason.invalidTimeout("timeoutSeconds")
      }
    }
  }
}

struct RunCommandToolExecutor: TypedToolExecutor {
  static let codec = ToolCodec<RunCommandInput>(
    definition: ToolDefinition.runCommand,
    decodeArguments: RunCommandInput.decodeToolArguments,
    makePayload: ToolCallPayload.runCommand,
    extractInput: { payload in
      guard case .runCommand(let input) = payload else {
        throw ToolInputDecodingError.payloadMismatch(
          expected: ToolDefinition.runCommand.name.rawValue,
          actual: payload.toolName.rawValue
        )
      }
      return input
    }
  )

  static let minimumTimeoutSeconds = 1
  static let maximumTimeoutSeconds = 120

  private let bashExecutableURL: URL
  private let environment: [String: String]
  private let pathPrefixDirectories: [URL]
  private let maxOutputBytes: Int
  private let outputRefGenerator: @Sendable () -> String
  private let processRunner: any CommandProcessRunning

  init(
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

  func evaluatePermission(
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

  func previewApproval(
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

  func run(_ input: RunCommandInput, context: ToolContext) async -> ToolResultPayload {
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
