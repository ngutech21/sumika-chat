import Foundation

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

private final class PipeDataCollector: @unchecked Sendable {
  private let fileHandle: FileHandle
  private let lock = NSLock()
  private var data = Data()
  private var reachedEnd = false

  init(fileHandle: FileHandle) {
    self.fileHandle = fileHandle
    fileHandle.readabilityHandler = { [weak self] handle in
      let chunk = handle.availableData
      if chunk.isEmpty {
        handle.readabilityHandler = nil
      }
      self?.record(chunk)
    }
  }

  func snapshot(afterExitDrain duration: Duration) async -> Data {
    if !hasReachedEnd {
      try? await Task.sleep(for: duration)
    }

    return snapshotAndClose()
  }

  func close() {
    _ = snapshotAndClose()
  }

  private func snapshotAndClose() -> Data {
    fileHandle.readabilityHandler = nil
    try? fileHandle.close()

    lock.lock()
    let snapshot = data
    lock.unlock()
    return snapshot
  }

  private var hasReachedEnd: Bool {
    lock.lock()
    let value = reachedEnd
    lock.unlock()
    return value
  }

  private func record(_ chunk: Data) {
    lock.lock()
    if chunk.isEmpty {
      reachedEnd = true
    } else {
      data.append(chunk)
    }
    lock.unlock()
  }
}

public actor DefaultCommandProcessRunner: CommandProcessRunning {
  public init() {}

  public nonisolated func run(_ request: CommandProcessRequest) async throws -> CommandProcessResult
  {
    try await runCommandProcess(request)
  }
}

private func runCommandProcess(_ request: CommandProcessRequest) async throws
  -> CommandProcessResult
{
  let process = Process()
  process.executableURL = request.executableURL
  process.arguments = request.arguments
  process.environment = request.environment
  process.currentDirectoryURL = request.workingDirectoryURL

  let stdoutPipe = Pipe()
  let stderrPipe = Pipe()
  process.standardOutput = stdoutPipe
  process.standardError = stderrPipe
  let stdoutCollector = PipeDataCollector(fileHandle: stdoutPipe.fileHandleForReading)
  let stderrCollector = PipeDataCollector(fileHandle: stderrPipe.fileHandleForReading)

  let startedAt = Date()
  do {
    try process.run()
  } catch {
    stdoutCollector.close()
    stderrCollector.close()
    throw error
  }

  let waitOutcome = await withTaskCancellationHandler {
    let outcome = await waitForExitOrTimeout(
      process: process,
      timeoutSeconds: request.timeoutSeconds
    )
    return Task.isCancelled ? .cancelled : outcome
  } onCancel: {
    if process.isRunning {
      terminateProcessTree(process)
    }
  }

  let durationMs = max(Int(Date().timeIntervalSince(startedAt) * 1000), 0)
  let pipeDrainGrace: Duration = .milliseconds(25)
  async let stdoutData = stdoutCollector.snapshot(afterExitDrain: pipeDrainGrace)
  async let stderrData = stderrCollector.snapshot(afterExitDrain: pipeDrainGrace)

  return CommandProcessResult(
    exitCode: process.isRunning ? nil : process.terminationStatus,
    durationMs: durationMs,
    stdout: String(data: await stdoutData, encoding: .utf8) ?? "",
    stderr: String(data: await stderrData, encoding: .utf8) ?? "",
    timedOut: waitOutcome == .timedOut,
    cancelled: waitOutcome == .cancelled
  )
}

private func waitForExitOrTimeout(
  process: Process,
  timeoutSeconds: Int
) async -> CommandProcessWaitOutcome {
  do {
    return try await withThrowingTaskGroup(of: CommandProcessWaitOutcome.self) { group in
      group.addTask {
        await waitUntilProcessExits(process)
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
        _ = await waitUntilProcessExits(process, timeoutMilliseconds: 1_000)
      }
      group.cancelAll()
      return outcome
    }
  } catch {
    if process.isRunning {
      terminateProcessTree(process)
    }
    _ = await waitUntilProcessExits(process, timeoutMilliseconds: 1_000)
    return .cancelled
  }
}

private func waitUntilProcessExits(
  _ process: Process,
  timeoutMilliseconds: Int? = nil
) async {
  let deadline = timeoutMilliseconds.map {
    Date().addingTimeInterval(TimeInterval($0) / 1_000)
  }

  while process.isRunning {
    if Task.isCancelled {
      return
    }
    if let deadline, Date() >= deadline {
      return
    }
    try? await Task.sleep(for: .milliseconds(10))
  }
}

private func terminateProcessTree(_ process: Process) {
  let rootPID = process.processIdentifier
  let descendantPIDs = processDescendantIDs(of: rootPID)
  terminateProcesses(descendantPIDs.reversed() + [rootPID])
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
    arguments: ["-KILL"] + processIDs.map(String.init)
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
