import Darwin
import Foundation
import Testing

@testable import SumikaCore

struct OwnedProcessTests {
  @Test(arguments: [0, 64])
  func drainsBothStreamsWithoutNewlinesAfterCaptureFills(limit: Int) async throws {
    let result = try await DefaultCommandProcessRunner().run(
      request(
        """
        /bin/dd if=/dev/zero bs=65536 count=16 2>/dev/null &
        (/bin/dd if=/dev/zero bs=65536 count=16 2>/dev/null) >&2 &
        wait
        """,
        maxStdoutBytes: limit,
        maxStderrBytes: limit
      )
    )

    #expect(result.exitCode == 0)
    #expect(!result.timedOut)
    #expect(result.stdoutData.count == limit)
    #expect(result.stderr.utf8.count == limit)
    #expect(result.stdoutOmittedBytes == 1_048_576 - limit)
    #expect(result.stderrOmittedBytes == 1_048_576 - limit)
    #expect(result.stdoutTruncated)
    #expect(result.stderrTruncated)
  }

  @Test
  func headTailRetentionKeepsInitialAndFinalDiagnostics() async throws {
    let result = try await DefaultCommandProcessRunner().run(
      request(
        """
        printf 'START'
        /bin/dd if=/dev/zero bs=65536 count=16 2>/dev/null
        printf 'FINAL'
        printf 'old stderr: last diagnostic' >&2
        """,
        maxStdoutBytes: 128,
        maxStderrBytes: 15,
        stdoutRetention: .headTail,
        stderrRetention: .tail
      )
    )

    #expect(result.stdout.hasPrefix("START"))
    #expect(result.stdout.hasSuffix("FINAL"))
    #expect(result.stdout.contains("bytes omitted during capture"))
    #expect(result.stdout.utf8.count <= 128)
    #expect(result.stdoutData.count + result.stdoutOmittedBytes == 1_048_586)
    #expect(result.stderr == "last diagnostic")
    #expect(result.stderrOmittedBytes == 12)
  }

  @Test
  func prefixPreservesRawNULDelimitedBytesWhenLimitSplitsUTF8() async throws {
    let result = try await DefaultCommandProcessRunner().run(
      request("printf 'a.swift\\0\\303\\251'", maxStdoutBytes: 9)
    )

    #expect(result.stdoutData == Data([97, 46, 115, 119, 105, 102, 116, 0, 0xC3]))
    #expect(result.stdout.utf8.count <= 9)
    #expect(result.stdoutOmittedBytes == 1)
    #expect(result.stdoutTruncated)
  }

  @Test
  func invalidUTF8CannotExpandDecodedTextPastItsBudget() async throws {
    let result = try await DefaultCommandProcessRunner().run(
      request(
        "printf '\\377\\377\\377\\377\\377\\377\\377\\377\\377\\377\\377\\377'",
        maxStdoutBytes: 8
      )
    )

    #expect(result.stdoutData == Data(repeating: 0xFF, count: 8))
    #expect(result.stdout.utf8.count <= 8)
    #expect(result.stdoutOmittedBytes == 4)
  }

  @Test(arguments: [ProcessOutputRetention.headTail, .tail])
  func invalidUTF8BeforeFinalDiagnosticPreservesTheEnding(
    retention: ProcessOutputRetention
  ) async throws {
    let input = Data("START".utf8) + Data(repeating: 0xFF, count: 1_024) + Data("FINAL".utf8)
    let result = try await DefaultCommandProcessRunner().run(
      request(
        "/bin/cat",
        standardInput: input,
        maxStdoutBytes: 128,
        stdoutRetention: retention
      )
    )

    #expect(result.stdout.hasSuffix("FINAL"))
    #expect(result.stdout.utf8.count <= 128)
    #expect(result.stdoutData.count + result.stdoutOmittedBytes == 1_034)
    if retention == .headTail {
      #expect(result.stdout.hasPrefix("START"))
      #expect(result.stdout.contains("bytes omitted during capture"))
    }
  }

  @Test
  func invalidUTF8WithinCaptureBudgetDoesNotHideLaterDiagnostics() async throws {
    let result = try await DefaultCommandProcessRunner().run(
      request(
        "printf '\\377%.0s' {1..32}; printf '\\357\\277\\275NEEDLE'",
        maxStdoutBytes: 48,
        stdoutRetention: .headTail
      )
    )

    #expect(result.stdout == String(repeating: "?", count: 32) + "\u{FFFD}NEEDLE")
    #expect(result.stdoutOmittedBytes == 0)
    #expect(!result.stdoutTruncated)
    #expect(result.stdout.utf8.count == result.stdoutData.count)
  }

  @Test
  func deadlineIncludesBlockedStandardInput() async throws {
    let startedAt = ContinuousClock.now
    let result = try await DefaultCommandProcessRunner().run(
      request(
        "/bin/sleep 6; /bin/cat >/dev/null",
        timeoutSeconds: 1,
        standardInput: Data(repeating: 65, count: 1_048_576)
      )
    )

    #expect(result.timedOut)
    #expect(!result.cancelled)
    #expect(startedAt.duration(to: .now) < .seconds(5))
  }

  @Test(arguments: [0, 1_048_576])
  func standardInputClosesAndProgressesWhileOutputIsDrained(byteCount: Int) async throws {
    let result = try await DefaultCommandProcessRunner().run(
      request(
        "/bin/cat",
        standardInput: byteCount == 0 ? nil : Data(repeating: 65, count: byteCount),
        maxStdoutBytes: 64
      )
    )

    #expect(result.exitCode == 0)
    #expect(!result.timedOut)
    #expect(result.stdoutData == Data(repeating: 65, count: byteCount == 0 ? 0 : 64))
    #expect(result.stdoutOmittedBytes == (byteCount == 0 ? 0 : 1_048_512))
  }

  @Test
  func earlyExitWhileWritingInputDoesNotRaiseSIGPIPE() async throws {
    let result = try await DefaultCommandProcessRunner().run(
      request("exit 7", standardInput: Data(repeating: 65, count: 1_048_576))
    )

    #expect(result.exitCode == 7)
    #expect(!result.timedOut)
    #expect(!result.cancelled)
  }

  @Test
  func launchFailureThrowsPromptly() async throws {
    var request = request("")
    request.executableURL = URL(filePath: "/nonexistent/sumika-process-test-\(UUID())")
    let startedAt = ContinuousClock.now

    await #expect(throws: (any Error).self) {
      try await DefaultCommandProcessRunner().run(request)
    }

    #expect(startedAt.duration(to: .now) < .seconds(2))
  }

  @Test
  func cancellationBeforeStartDoesNotLaunchTheChild() async throws {
    let directory = try makeProcessTestDirectory()
    let pidFile = directory.appendingPathComponent("root.pid")
    defer { cleanUpProcessTest(directory, pidFiles: [pidFile]) }
    let processRequest = request(
      "printf '%s' \"$$\" > \"$PID_FILE\"; exec /bin/sleep 15",
      environment: ["PID_FILE": pidFile.path]
    )
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await DefaultCommandProcessRunner().run(processRequest)
    }

    let result = try await task.value

    #expect(result.cancelled)
    #expect(result.exitCode == nil)
    #expect(!FileManager.default.fileExists(atPath: pidFile.path))
  }

  @Test
  func cancellationInterruptsBlockedStandardInputAndReapsTheChild() async throws {
    let directory = try makeProcessTestDirectory()
    let pidFile = directory.appendingPathComponent("root.pid")
    defer { cleanUpProcessTest(directory, pidFiles: [pidFile]) }
    let processRequest = request(
      """
      IFS= read -r -n 1 value
      printf '%s' "$$" > "$PID_FILE"
      exec /bin/sleep 15
      """,
      standardInput: Data(repeating: 65, count: 1_048_576),
      environment: ["PID_FILE": pidFile.path]
    )
    let task = Task { try await DefaultCommandProcessRunner().run(processRequest) }
    defer { task.cancel() }
    let processID = try await readProcessIDWhenReady(pidFile)
    let cancelledAt = ContinuousClock.now

    task.cancel()
    let result = try await task.value

    #expect(result.cancelled)
    #expect(!result.timedOut)
    #expect(cancelledAt.duration(to: .now) < .seconds(4))
    try await expectProcessStopped(processID)
  }

  @Test(arguments: [false, true])
  func timeoutAndCancellationEscalateForGroupIgnoringSIGTERM(cancel: Bool) async throws {
    let directory = try makeProcessTestDirectory()
    let pidFile = directory.appendingPathComponent("child.pid")
    let rootFile = directory.appendingPathComponent("root.pid")
    defer { cleanUpProcessTest(directory, pidFiles: [pidFile, rootFile]) }
    let processRequest = request(
      """
      trap '' TERM
      printf '%s' "$$" > "$ROOT_FILE"
      /bin/bash -c 'trap "" TERM; printf "%s" "$$" > "$PID_FILE"; exec /bin/sleep 15' &
      wait
      """,
      timeoutSeconds: cancel ? 10 : 1,
      environment: ["PID_FILE": pidFile.path, "ROOT_FILE": rootFile.path]
    )
    let startedAt = ContinuousClock.now
    let task = Task { try await DefaultCommandProcessRunner().run(processRequest) }
    defer { task.cancel() }
    let childPID = try await readProcessIDWhenReady(pidFile)
    let rootPID = try await readProcessIDWhenReady(rootFile)
    if cancel {
      task.cancel()
    }

    let result = try await task.value

    #expect(result.cancelled == cancel)
    #expect(result.timedOut == !cancel)
    #expect(startedAt.duration(to: .now) < .seconds(5))
    try await expectProcessStopped(childPID)
    try await expectProcessStopped(rootPID)
  }

  @Test
  func rootExitCleansUpDescendantThatKeepsPipeHandlesOpen() async throws {
    let directory = try makeProcessTestDirectory()
    let pidFile = directory.appendingPathComponent("child.pid")
    defer { cleanUpProcessTest(directory, pidFiles: [pidFile]) }
    let startedAt = ContinuousClock.now
    let result = try await DefaultCommandProcessRunner().run(
      request(
        """
        /bin/sleep 15 &
        printf '%s' "$!" > "$PID_FILE"
        printf 'root completed'
        exit 0
        """,
        environment: ["PID_FILE": pidFile.path]
      )
    )
    let childPID = try await readProcessIDWhenReady(pidFile)

    #expect(result.exitCode == 0)
    #expect(result.stdout == "root completed")
    #expect(!result.timedOut)
    #expect(!result.cancelled)
    #expect(startedAt.duration(to: .now) < .seconds(4))
    try await expectProcessStopped(childPID)
  }

  @Test
  func launchedProcessOwnsSeparateProcessGroup() async throws {
    let directory = try makeProcessTestDirectory()
    let pidFile = directory.appendingPathComponent("root.pid")
    defer { cleanUpProcessTest(directory, pidFiles: [pidFile]) }
    let processRequest = request(
      "printf '%s' \"$$\" > \"$PID_FILE\"; exec /bin/sleep 15",
      environment: ["PID_FILE": pidFile.path]
    )
    let task = Task { try await DefaultCommandProcessRunner().run(processRequest) }
    defer { task.cancel() }
    let processID = try await readProcessIDWhenReady(pidFile)

    #expect(getpgid(processID) == processID)
    #expect(getpgid(processID) != getpgrp())

    task.cancel()
    let result = try await task.value
    #expect(result.cancelled)
    try await expectProcessStopped(processID)
  }

  private func request(
    _ script: String,
    timeoutSeconds: Int = 10,
    standardInput: Data? = nil,
    maxStdoutBytes: Int = 256,
    maxStderrBytes: Int = 256,
    stdoutRetention: ProcessOutputRetention = .prefix,
    stderrRetention: ProcessOutputRetention = .prefix,
    environment: [String: String] = [:]
  ) -> CommandProcessRequest {
    CommandProcessRequest(
      executableURL: URL(filePath: "/bin/bash"),
      arguments: ["-c", script],
      environment: environment,
      workingDirectoryURL: FileManager.default.temporaryDirectory,
      timeoutSeconds: timeoutSeconds,
      standardInput: standardInput,
      maxStdoutBytes: maxStdoutBytes,
      maxStderrBytes: maxStderrBytes,
      stdoutRetention: stdoutRetention,
      stderrRetention: stderrRetention
    )
  }
}

private func makeProcessTestDirectory() throws -> URL {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("SumikaOwnedProcessTests-\(UUID())", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}

private func readProcessIDWhenReady(_ file: URL) async throws -> Int32 {
  let deadline = ContinuousClock.now + .seconds(3)
  while ContinuousClock.now < deadline {
    if let contents = try? String(contentsOf: file, encoding: .utf8),
      let processID = Int32(contents), processID > 1
    {
      return processID
    }
    try await Task.sleep(for: .milliseconds(10))
  }
  throw ProcessTestError.missingProcessID
}

private func expectProcessStopped(_ processID: Int32) async throws {
  let deadline = ContinuousClock.now + .seconds(2)
  while ContinuousClock.now < deadline {
    if kill(processID, 0) == -1, errno == ESRCH {
      return
    }
    try await Task.sleep(for: .milliseconds(10))
  }
  Issue.record("Child process \(processID) remained alive after cleanup completed.")
}

private func cleanUpProcessTest(_ directory: URL, pidFiles: [URL]) {
  for file in pidFiles {
    if let contents = try? String(contentsOf: file, encoding: .utf8),
      let processID = Int32(contents), processID > 1
    {
      _ = kill(processID, SIGKILL)
    }
  }
  try? FileManager.default.removeItem(at: directory)
}

private enum ProcessTestError: Error {
  case missingProcessID
}
