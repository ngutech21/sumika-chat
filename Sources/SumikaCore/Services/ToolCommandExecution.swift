import Foundation

internal actor LatestCommandResultStore {
  package static let defaultMaxOutputRefsPerSession = 4
  package static let defaultMaxOutputBytesPerSession = 2 * 1024 * 1024

  private struct Key: Hashable, Sendable {
    var workspaceID: Workspace.ID
    var sessionID: ChatSession.ID
  }

  private let maxOutputRefsPerSession: Int
  private let maxOutputBytesPerSession: Int
  private var results: [Key: RunCommandResult] = [:]
  private var outputs: [Key: [String: CommandOutputRecord]] = [:]
  private var outputOrder: [Key: [String]] = [:]

  package init(
    maxOutputRefsPerSession: Int = LatestCommandResultStore.defaultMaxOutputRefsPerSession,
    maxOutputBytesPerSession: Int = LatestCommandResultStore.defaultMaxOutputBytesPerSession
  ) {
    self.maxOutputRefsPerSession = max(maxOutputRefsPerSession, 1)
    self.maxOutputBytesPerSession = max(maxOutputBytesPerSession, 1)
  }

  // Test-only; exercised through @testable import.
  // swiftlint:disable:next unused_declaration
  package func result(workspaceID: Workspace.ID, sessionID: ChatSession.ID) -> RunCommandResult? {
    results[Key(workspaceID: workspaceID, sessionID: sessionID)]
  }

  // Test-only convenience overload; exercised through @testable import.
  // swiftlint:disable:next unused_declaration
  package func record(
    _ result: RunCommandResult,
    workspaceID: Workspace.ID,
    sessionID: ChatSession.ID
  ) {
    results[Key(workspaceID: workspaceID, sessionID: sessionID)] = result
  }

  @discardableResult
  package func record(
    _ result: RunCommandResult,
    output: CommandOutputRecord,
    workspaceID: Workspace.ID,
    sessionID: ChatSession.ID
  ) -> Bool {
    let key = Key(workspaceID: workspaceID, sessionID: sessionID)
    outputs[key, default: [:]][output.outputRef] = output
    var order = outputOrder[key, default: []].filter { $0 != output.outputRef }
    order.append(output.outputRef)
    outputOrder[key] = order
    pruneOutputs(for: key)
    let retained = outputs[key]?[output.outputRef] != nil
    var storedResult = result
    if !retained {
      storedResult.outputRef = nil
    }
    results[key] = storedResult
    return retained
  }

  package func output(
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

internal struct CommandOutputRecord: Equatable, Sendable {
  package var outputRef: String
  package var stdout: String
  package var stderr: String

  var stdoutOmittedBytes: Int
  var stderrOmittedBytes: Int

  package init(
    outputRef: String, stdout: String, stderr: String,
    stdoutOmittedBytes: Int = 0, stderrOmittedBytes: Int = 0
  ) {
    self.outputRef = outputRef
    self.stdoutOmittedBytes = stdoutOmittedBytes
    self.stderrOmittedBytes = stderrOmittedBytes
    self.stdout = stdout
    self.stderr = stderr
  }

  package var byteCount: Int {
    outputRef.utf8.count + stdout.utf8.count + stderr.utf8.count
  }
}

internal struct CommandProcessRequest: Equatable, Sendable {
  var executableURL: URL
  var arguments: [String]
  var environment: [String: String]
  var workingDirectoryURL: URL
  var timeoutSeconds: Int
  var standardInput: Data?
  var maxStdoutBytes: Int
  var maxStderrBytes: Int
  var stdoutRetention: ProcessOutputRetention
  var stderrRetention: ProcessOutputRetention

  init(
    executableURL: URL, arguments: [String], environment: [String: String],
    workingDirectoryURL: URL, timeoutSeconds: Int, standardInput: Data? = nil,
    maxStdoutBytes: Int, maxStderrBytes: Int,
    stdoutRetention: ProcessOutputRetention = .prefix,
    stderrRetention: ProcessOutputRetention = .prefix
  ) {
    self.executableURL = executableURL
    self.arguments = arguments
    self.environment = environment
    self.workingDirectoryURL = workingDirectoryURL
    self.timeoutSeconds = timeoutSeconds
    self.standardInput = standardInput
    self.maxStdoutBytes = maxStdoutBytes
    self.maxStderrBytes = maxStderrBytes
    self.stdoutRetention = stdoutRetention
    self.stderrRetention = stderrRetention
  }
}

internal struct CommandProcessResult: Equatable, Sendable {
  var exitCode: Int32?
  var durationMs: Int
  var stdout: String
  var stdoutData: Data
  var stderr: String
  var termination: OwnedProcess.Termination
  var stdoutTruncated: Bool
  var stderrTruncated: Bool
  var stdoutOmittedBytes: Int
  var stderrOmittedBytes: Int

  var timedOut: Bool { termination == .timedOut }
  var cancelled: Bool { termination == .cancelled }

  init(
    exitCode: Int32?, durationMs: Int, stdout: String, stderr: String,
    stdoutData: Data? = nil, timedOut: Bool = false, cancelled: Bool = false,
    stdoutTruncated: Bool = false, stderrTruncated: Bool = false,
    stdoutOmittedBytes: Int = 0, stderrOmittedBytes: Int = 0
  ) {
    self.exitCode = exitCode
    self.durationMs = durationMs
    self.stdout = stdout
    self.stdoutData = stdoutData ?? Data(stdout.utf8)
    self.stderr = stderr
    self.termination = cancelled ? .cancelled : (timedOut ? .timedOut : .exited(exitCode ?? -1))
    self.stdoutTruncated = stdoutTruncated || stdoutOmittedBytes > 0
    self.stderrTruncated = stderrTruncated || stderrOmittedBytes > 0
    self.stdoutOmittedBytes = stdoutOmittedBytes
    self.stderrOmittedBytes = stderrOmittedBytes
  }
}

internal protocol CommandProcessRunning: Sendable {
  func run(_ request: CommandProcessRequest) async throws -> CommandProcessResult
}

internal struct DefaultCommandProcessRunner: CommandProcessRunning {
  func run(_ request: CommandProcessRequest) async throws -> CommandProcessResult {
    let owner: OwnedProcess
    do {
      owner = try await OwnedProcess.start(
        executableURL: request.executableURL, arguments: request.arguments,
        environment: request.environment, workingDirectoryURL: request.workingDirectoryURL,
        stdout: .capture(limit: request.maxStdoutBytes, retention: request.stdoutRetention),
        stderrLimit: request.maxStderrBytes, stderrRetention: request.stderrRetention,
        maxWriteBytes: request.standardInput?.count ?? 0, maxPendingWrites: 1,
        timeout: .seconds(request.timeoutSeconds)
      )
    } catch is CancellationError {
      return CommandProcessResult(
        exitCode: nil, durationMs: 0, stdout: "", stderr: "", cancelled: true
      )
    }
    let output = await withTaskCancellationHandler {
      if let input = request.standardInput {
        // EPIPE can simply mean that the child exited without reading all input.
        // The owner settles exit/failure and always completes bounded cleanup.
        try? await owner.write(input)
      }
      await owner.closeInput()
      return await owner.wait()
    } onCancel: {
      Task { await owner.stop(.cancelled) }
    }
    if case .failed(let failure) = output.termination { throw failure }
    let exitCode: Int32? = if case .exited(let code) = output.termination { code } else { nil }
    var result = CommandProcessResult(
      exitCode: exitCode, durationMs: output.durationMs, stdout: output.stdout,
      stderr: output.stderr, stdoutData: output.stdoutData,
      stdoutOmittedBytes: output.stdoutOmittedBytes, stderrOmittedBytes: output.stderrOmittedBytes
    )
    result.termination = output.termination
    return result
  }
}
