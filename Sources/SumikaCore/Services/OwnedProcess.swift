import Darwin
import Foundation

/// Process, descriptor, capture, and continuation state is confined to queue;
/// the admission lock reserves write slots before their data enters that queue.
final class OwnedProcess: @unchecked Sendable {
  enum Stdout: Sendable {
    case capture(limit: Int, retention: ProcessOutputRetention)
    case frames(maxBytes: Int, queuedFrames: Int)
  }

  enum Failure: Error, LocalizedError, Equatable, Sendable {
    case resourceLimit(String)
    // swiftlint:disable:next identifier_name
    case io(String)
    case launch(String)

    var errorDescription: String? {
      switch self {
      case .resourceLimit(let detail), .io(let detail), .launch(let detail): detail
      }
    }
  }

  enum Termination: Equatable, Sendable {
    case exited(Int32)
    case timedOut
    case cancelled
    case stopped
    case failed(Failure)
  }

  struct Result: Sendable {
    var termination: Termination
    var stdoutData: Data
    var stdout: String
    var stderr: String
    var stdoutOmittedBytes: Int
    var stderrOmittedBytes: Int
    var durationMs: Int
  }

  private struct PendingWrite {
    var data: Data
    var offset = 0
    var continuation: CheckedContinuation<Void, any Error>
  }

  private let queue = DispatchQueue(label: "chat.sumika.owned-process")
  private let process = Process()
  private let stdoutPolicy: Stdout
  private let maxWriteBytes: Int
  private let maxPendingWrites: Int
  private let writeAdmissionLock = NSLock()
  private var admittedWrites = 0
  private var stdoutCapture: ProcessOutputCapture
  private var stderrCapture: ProcessOutputCapture
  private var stdoutSource: (any DispatchSourceRead)?
  private var stdoutSourceSuspended = false
  private var stderrSource: (any DispatchSourceRead)?
  private var inputSource: (any DispatchSourceWrite)?
  private var inputSourceSuspended = false
  private var openReaders = 0
  private var closingInputs = 0
  private var inputHandle: FileHandle?
  private var writes: [PendingWrite] = []
  private var frames: [Data] = []
  private var pendingFrame = Data()
  private var deferredStdout = Data()
  private var frameWaiter: CheckedContinuation<Data?, any Error>?
  private var stdoutEnded = false
  private var terminalReason: Termination?
  private var result: Result?
  private var isFinishing = false
  private var waiters: [CheckedContinuation<Result, Never>] = []
  private var timeoutWork: DispatchWorkItem?
  private var startedAt = ContinuousClock.now
  private var stopStartedAt: ContinuousClock.Instant?
  private var sentKill = false
  private var processGroup: Int32 = 0

  private init(
    stdout: Stdout, stderrLimit: Int, stderrRetention: ProcessOutputRetention,
    maxWriteBytes: Int, maxPendingWrites: Int
  ) {
    stdoutPolicy = stdout
    self.maxWriteBytes = max(0, maxWriteBytes)
    self.maxPendingWrites = max(1, maxPendingWrites)
    if case .capture(let limit, let retention) = stdout {
      stdoutCapture = ProcessOutputCapture(limit: limit, retention: retention)
    } else {
      stdoutCapture = ProcessOutputCapture(limit: 0, retention: .prefix)
    }
    stderrCapture = ProcessOutputCapture(limit: stderrLimit, retention: stderrRetention)
  }

  static func start(
    executableURL: URL, arguments: [String], environment: [String: String],
    workingDirectoryURL: URL, stdout: Stdout, stderrLimit: Int,
    stderrRetention: ProcessOutputRetention = .tail,
    maxWriteBytes: Int = 8 * 1024 * 1024 + 1, maxPendingWrites: Int = 2,
    timeout: Duration? = nil
  ) async throws -> OwnedProcess {
    let owner = OwnedProcess(
      stdout: stdout, stderrLimit: stderrLimit, stderrRetention: stderrRetention,
      maxWriteBytes: maxWriteBytes, maxPendingWrites: maxPendingWrites
    )
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        owner.queue.async {
          do {
            guard owner.terminalReason == nil else { throw CancellationError() }
            try owner.launch(
              executableURL: executableURL, arguments: arguments, environment: environment,
              workingDirectoryURL: workingDirectoryURL, timeout: timeout
            )
            continuation.resume()
          } catch {
            owner.finishLaunchFailure(error)
            continuation.resume(throwing: error)
          }
        }
      }
    } onCancel: {
      owner.requestStop(.cancelled)
    }
    return owner
  }

  func write(_ data: Data) async throws {
    let admitted = writeAdmissionLock.withLock {
      guard data.count <= maxWriteBytes, admittedWrites < maxPendingWrites else { return false }
      admittedWrites += 1
      return true
    }
    guard admitted else {
      let failure = Failure.resourceLimit("Process input exceeded its bounded write allowance.")
      requestStop(.failed(failure))
      throw failure
    }
    defer { writeAdmissionLock.withLock { admittedWrites -= 1 } }
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        queue.async {
          guard self.terminalReason == nil, self.inputHandle != nil else {
            continuation.resume(throwing: Failure.io("Process input is closed."))
            return
          }
          self.writes.append(PendingWrite(data: data, continuation: continuation))
          self.drainWrites()
        }
      }
    } onCancel: {
      self.requestStop(.cancelled)
    }
  }

  func closeInput() async {
    await withCheckedContinuation { continuation in
      queue.async {
        self.closeInputHandle()
        continuation.resume()
      }
    }
  }

  func nextFrame() async throws -> Data? {
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        queue.async {
          if case .failed(let failure) = self.terminalReason {
            continuation.resume(throwing: failure)
          } else if !self.frames.isEmpty {
            continuation.resume(returning: self.frames.removeFirst())
            self.resumeStdoutAfterFrame()
          } else if self.stdoutEnded || self.result != nil {
            continuation.resume(returning: nil)
          } else if self.frameWaiter != nil {
            continuation.resume(throwing: Failure.io("Process output already has a reader."))
          } else {
            self.frameWaiter = continuation
          }
        }
      }
    } onCancel: {
      self.requestStop(.cancelled)
    }
  }

  func wait() async -> Result {
    await withCheckedContinuation { continuation in
      queue.async {
        if let result = self.result {
          continuation.resume(returning: result)
        } else {
          self.waiters.append(continuation)
        }
      }
    }
  }

  @discardableResult
  func stop(_ reason: Termination = .cancelled) async -> Result {
    requestStop(reason)
    return await wait()
  }

  private func launch(
    executableURL: URL, arguments: [String], environment: [String: String],
    workingDirectoryURL: URL, timeout: Duration?
  ) throws {
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    let handles = [
      stdinPipe.fileHandleForReading, stdinPipe.fileHandleForWriting,
      stdoutPipe.fileHandleForReading, stdoutPipe.fileHandleForWriting,
      stderrPipe.fileHandleForReading, stderrPipe.fileHandleForWriting,
    ]
    var launched = false
    defer {
      if !launched { for handle in handles { try? handle.close() } }
    }
    process.executableURL = executableURL
    process.arguments = arguments
    process.environment = environment
    process.currentDirectoryURL = workingDirectoryURL
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    for handle in [
      stdinPipe.fileHandleForWriting, stdoutPipe.fileHandleForReading,
      stderrPipe.fileHandleForReading,
    ] {
      let descriptor = handle.fileDescriptor
      let flags = fcntl(descriptor, F_GETFL)
      guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
        throw Failure.launch("Could not configure nonblocking process I/O.")
      }
    }
    guard fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
      throw Failure.launch("Could not protect process input from SIGPIPE.")
    }
    startedAt = .now
    process.terminationHandler = { [weak self] process in
      guard let self else { return }
      self.queue.async { self.beginStop(.exited(process.terminationStatus)) }
    }
    try process.run()
    processGroup = process.processIdentifier
    // Foundation creates the group on macOS. Never signal our own group if
    // platform behavior changes; short-lived children may already have exited.
    let group = getpgid(processGroup)
    if group != -1, group != processGroup {
      processGroup = 0
      _ = kill(process.processIdentifier, SIGKILL)
      throw Failure.launch("The child did not receive an isolated process group.")
    }
    try? stdinPipe.fileHandleForReading.close()
    try? stdoutPipe.fileHandleForWriting.close()
    try? stderrPipe.fileHandleForWriting.close()
    inputHandle = stdinPipe.fileHandleForWriting
    stdoutSource = makeReader(stdoutPipe.fileHandleForReading, isStdout: true)
    stderrSource = makeReader(stderrPipe.fileHandleForReading, isStdout: false)
    launched = true
    if let timeout {
      let work = DispatchWorkItem { [weak self] in self?.beginStop(.timedOut) }
      timeoutWork = work
      queue.asyncAfter(deadline: .now() + timeout.timeInterval, execute: work)
    }
  }

  private func makeReader(_ handle: FileHandle, isStdout: Bool) -> any DispatchSourceRead {
    openReaders += 1
    let descriptor = handle.fileDescriptor
    let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
    source.setEventHandler { [weak self] in self?.read(descriptor, isStdout: isStdout) }
    source.setCancelHandler { [weak self] in
      try? handle.close()
      self?.openReaders -= 1
      self?.completeAfterClosingDescriptors()
    }
    source.resume()
    return source
  }

  private func read(_ descriptor: Int32, isStdout: Bool) {
    guard isStdout ? stdoutSource != nil && !stdoutSourceSuspended : stderrSource != nil else {
      return
    }
    var bytes = [UInt8](repeating: 0, count: 16 * 1024)
    // Yield to cancellation and the other pipe even under continuous output.
    for _ in 0..<4 {
      let count = Darwin.read(descriptor, &bytes, bytes.count)
      if count > 0 {
        let data = Data(bytes.prefix(count))
        if isStdout { ingestStdout(data) } else { stderrCapture.append(data) }
        if result != nil || (isStdout && stdoutSourceSuspended) { return }
      } else if count == 0 {
        endReader(isStdout: isStdout)
        return
      } else if errno == EINTR {
        continue
      } else if errno == EAGAIN || errno == EWOULDBLOCK {
        // After process cleanup, drain bytes already in the pipe without
        // waiting on a descendant that escaped the owned process group.
        if isFinishing { endReader(isStdout: isStdout) }
        return
      } else {
        beginStop(.failed(.io("Could not read process output (errno \(errno)).")))
        endReader(isStdout: isStdout)
        return
      }
    }
  }

  private func ingestStdout(_ data: Data) {
    switch stdoutPolicy {
    case .capture:
      stdoutCapture.append(data)
    case .frames(let maxBytes, let queuedFrames):
      switch terminalReason {
      case nil, .exited: break
      default: return
      }
      var remaining = data[...]
      while !remaining.isEmpty {
        if frames.count >= queuedFrames, frameWaiter == nil {
          // Keep only the remainder of this 16 KiB read. Leave subsequent
          // bytes in the pipe so its capacity provides producer backpressure.
          deferredStdout = Data(remaining)
          stdoutSource?.suspend()
          stdoutSourceSuspended = true
          return
        }
        let newline = remaining.firstIndex(of: 10)
        let part = newline.map { remaining[..<$0] } ?? remaining
        guard part.count <= maxBytes - pendingFrame.count else {
          beginStop(.failed(.resourceLimit("Process output frame exceeded \(maxBytes) bytes.")))
          return
        }
        pendingFrame.append(part)
        guard let newline else { return }
        if !pendingFrame.isEmpty {
          if let waiter = frameWaiter {
            frameWaiter = nil
            waiter.resume(returning: pendingFrame)
          } else {
            frames.append(pendingFrame)
          }
          pendingFrame = Data()
        }
        remaining = remaining[remaining.index(after: newline)...]
      }
    }
  }

  private func resumeStdoutAfterFrame() {
    guard stdoutSourceSuspended else { return }
    let deferred = deferredStdout
    deferredStdout = Data()
    stdoutSource?.resume()
    stdoutSourceSuspended = false
    ingestStdout(deferred)
  }

  private func cancelStdoutSource() {
    if stdoutSourceSuspended { stdoutSource?.resume() }
    stdoutSourceSuspended = false
    stdoutSource?.cancel()
    stdoutSource = nil
  }

  private func endReader(isStdout: Bool) {
    if isStdout {
      cancelStdoutSource()
      stdoutEnded = true
      if !pendingFrame.isEmpty {
        let failure = Failure.io("Process output ended inside a newline-delimited frame.")
        beginStop(.failed(failure))
      }
      if let waiter = frameWaiter {
        frameWaiter = nil
        waiter.resume(returning: nil)
      }
    } else {
      stderrSource?.cancel()
      stderrSource = nil
    }
  }

  private func drainWrites() {
    guard let inputHandle, terminalReason == nil else { return }
    var remainingBudget = 64 * 1024
    while !writes.isEmpty, remainingBudget > 0 {
      let write = writes[0]
      if write.offset == write.data.count {
        writes.removeFirst().continuation.resume()
        continue
      }
      let count = write.data.withUnsafeBytes { bytes -> Int in
        guard let base = bytes.baseAddress else { return 0 }
        return Darwin.write(
          inputHandle.fileDescriptor, base.advanced(by: write.offset),
          min(remainingBudget, write.data.count - write.offset)
        )
      }
      if count > 0 {
        writes[0].offset += count
        remainingBudget -= count
        if writes[0].offset == writes[0].data.count {
          writes.removeFirst().continuation.resume()
        }
      } else if count < 0, errno == EINTR {
        continue
      } else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
        break
      } else {
        closeInputHandle()
        queue.asyncAfter(deadline: .now() + .milliseconds(10)) {
          if self.process.isRunning {
            self.beginStop(.failed(.io("The child closed its input pipe.")))
          } else {
            self.beginStop(.exited(self.process.terminationStatus))
          }
        }
        return
      }
    }
    if writes.isEmpty {
      if let inputSource, !inputSourceSuspended {
        inputSource.suspend()
        inputSourceSuspended = true
      }
    } else if let inputSource, inputSourceSuspended {
      inputSource.resume()
      inputSourceSuspended = false
    } else if inputSource == nil {
      let source = DispatchSource.makeWriteSource(
        fileDescriptor: inputHandle.fileDescriptor, queue: queue)
      source.setEventHandler { [weak self] in self?.drainWrites() }
      source.setCancelHandler { [weak self] in
        try? inputHandle.close()
        self?.closingInputs -= 1
        self?.completeAfterClosingDescriptors()
      }
      source.resume()
      inputSource = source
    }
  }

  private func closeInputHandle() {
    if let source = inputSource {
      closingInputs += 1
      if inputSourceSuspended { source.resume() }
      inputSourceSuspended = false
      source.cancel()
      inputSource = nil
    } else {
      try? inputHandle?.close()
    }
    inputHandle = nil
    let pending = writes
    writes.removeAll()
    for write in pending {
      write.continuation.resume(throwing: Failure.io("Process input is closed."))
    }
  }

  private func requestStop(_ reason: Termination) {
    queue.async { self.beginStop(reason) }
  }

  private func beginStop(_ reason: Termination) {
    guard result == nil else { return }
    if terminalReason != nil {
      guard case .exited = terminalReason else { return }
      if case .exited = reason { return }
    }
    terminalReason = reason
    closeInputHandle()
    switch reason {
    case .exited:
      break  // Keep the deadline while the consumer drains final protocol output.
    default:
      timeoutWork?.cancel()
      timeoutWork = nil
      frames.removeAll()
      pendingFrame.removeAll()
      deferredStdout = Data()
      if case .failed(let error) = reason {
        frameWaiter?.resume(throwing: error)
        frameWaiter = nil
      }
    }
    if isFinishing {
      finish()
    } else if stopStartedAt == nil {
      stopStartedAt = .now
      signalGroup(SIGTERM)
      pollCleanup()
    }
  }

  private func signalGroup(_ signal: Int32) {
    if processGroup > 1 {
      _ = kill(-processGroup, signal)
    }
  }

  private var groupExists: Bool {
    processGroup > 1 && (kill(-processGroup, 0) == 0 || errno == EPERM)
  }

  private func pollCleanup() {
    guard result == nil, let stopStartedAt else { return }
    let elapsed = stopStartedAt.duration(to: .now)
    if elapsed >= .milliseconds(500), !sentKill {
      sentKill = true
      signalGroup(SIGKILL)
    }
    if !process.isRunning, stdoutSource == nil, stderrSource == nil, !groupExists {
      finish()
    } else if elapsed >= .milliseconds(1_500) {
      signalGroup(SIGKILL)
      finish()
    } else {
      queue.asyncAfter(deadline: .now() + .milliseconds(10)) { self.pollCleanup() }
    }
  }

  private func finishLaunchFailure(_ error: any Error) {
    process.terminationHandler = nil
    closeInputHandle()
    if terminalReason == nil {
      beginStop(.failed(.launch(error.localizedDescription)))
    }
  }

  private func finish() {
    guard result == nil else { return }
    isFinishing = true
    stderrSource?.cancel()
    stderrSource = nil
    closeInputHandle()
    if case .exited = terminalReason, case .frames = stdoutPolicy {
      // Process teardown is bounded, but a slow consumer must be allowed to
      // drain final frames. Explicit stop/timeout can still abort this drain.
      if let stdoutSource { read(Int32(stdoutSource.handle), isStdout: true) }
    } else {
      cancelStdoutSource()
      stdoutEnded = true
      frameWaiter?.resume(returning: nil)
      frameWaiter = nil
    }
    completeAfterClosingDescriptors()
  }

  private func completeAfterClosingDescriptors() {
    guard isFinishing, result == nil, openReaders == 0, closingInputs == 0,
      let terminalReason
    else { return }
    timeoutWork?.cancel()
    timeoutWork = nil
    let stdout = stdoutCapture.snapshot()
    let stderr = stderrCapture.snapshot()
    let value = Result(
      termination: terminalReason, stdoutData: stdout.data, stdout: stdout.text,
      stderr: stderr.text,
      stdoutOmittedBytes: stdout.omittedBytes, stderrOmittedBytes: stderr.omittedBytes,
      durationMs: Int(startedAt.duration(to: .now).timeInterval * 1_000)
    )
    result = value
    let waiting = waiters
    waiters.removeAll()
    for waiter in waiting { waiter.resume(returning: value) }
  }
}

extension Duration {
  fileprivate var timeInterval: TimeInterval {
    let components = self.components
    return Double(components.seconds) + Double(components.attoseconds) / 1e18
  }
}
