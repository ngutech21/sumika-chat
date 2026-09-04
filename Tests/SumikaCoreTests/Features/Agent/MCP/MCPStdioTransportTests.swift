import Foundation
import MCP
import SumikaTestSupport
import Testing

@testable import SumikaCore

@Suite(TemporaryDirectoryTrait(named: "sumika-mcp-stdio-tests"))
struct MCPStdioTransportTests {
  @Test(arguments: [0, 2_000])
  func validBurstSurvivesActiveOrDelayedConsumerAfterProcessExit(delayMilliseconds: Int)
    async throws
  {
    let process = try await start(
      "printf '%s\\n' '{\"n\":1}' '{\"n\":2}' '{\"n\":3}' '{\"n\":4}'"
    )
    let transport = MCPStdioTransport(process: process, onReceiveEnded: {})
    let stream = await transport.receive()
    var iterator = stream.makeAsyncIterator()

    try await Task.sleep(for: .milliseconds(delayMilliseconds))
    for number in 1...4 {
      #expect(try await iterator.next() == Data("{\"n\":\(number)}".utf8))
    }
    await #expect(throws: MCPError.connectionClosed) {
      _ = try await iterator.next()
    }
    #expect(await process.wait().termination == .exited(0))
  }

  @Test
  func burstSpanningReadChunksPreservesFrameContentsAndOrder() async throws {
    let process = try await start(
      #"""
      /usr/bin/awk 'BEGIN {
        padding = sprintf("%020000d", 0);
        for (n = 1; n <= 12; n++) printf "{\"n\":%d,\"text\":\"%s\"}\n", n, padding;
      }'
      """#,
      frameLimit: 32 * 1024
    )
    let padding = String(repeating: "0", count: 20_000)

    for number in 1...12 {
      #expect(
        try await process.nextFrame() == Data("{\"n\":\(number),\"text\":\"\(padding)\"}".utf8))
    }
    #expect(try await process.nextFrame() == nil)
    #expect(await process.wait().termination == .exited(0))
  }

  @Test(arguments: [false, true])
  func stopUnblocksPausedStdoutEvenAfterProcessExit(exits: Bool) async throws {
    let process = try await start(
      "printf '%s\\n' '{\"n\":1}' '{\"n\":2}' '{\"n\":3}'; \(exits ? "exit 0" : "exec /bin/sleep 30")"
    )
    // Let the burst fill the queue and, for the exited child, pass the cleanup deadline.
    try await Task.sleep(for: .milliseconds(exits ? 2_000 : 100))
    let began = ContinuousClock.now

    let result = await process.stop(.cancelled)

    #expect(result.termination == .cancelled)
    #expect(ContinuousClock.now - began < .seconds(3))
    #expect(try await process.nextFrame() == nil)
  }

  @Test(arguments: [false, true])
  func deadlineUnblocksPausedStdout(exits: Bool) async throws {
    let process = try await start(
      "printf '%s\\n' '{\"n\":1}' '{\"n\":2}' '{\"n\":3}'; \(exits ? "exit 0" : "exec /bin/sleep 30")",
      timeout: .milliseconds(200)
    )
    let began = ContinuousClock.now
    let result = await process.wait()

    #expect(result.termination == .timedOut)
    #expect(ContinuousClock.now - began < .seconds(3))
    #expect(try await process.nextFrame() == nil)
  }

  @Test
  func toolResponseAfterNotificationBurstSurvivesImmediateExit() async throws {
    let script = #"""
      request_id() {
        printf '%s\n' "$1" | sed -E 's/.*"id":("[^"]*"|[0-9]+).*/\1/'
      }
      read -r line
      id=$(request_id "$line")
      printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"burst","version":"1.0"}}}\n' "$id"
      read -r line
      read -r line
      id=$(request_id "$line")
      printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"echo","inputSchema":{"type":"object"}}]}}\n' "$id"
      read -r line
      id=$(request_id "$line")
      printf '%s\n%s\n%s\n{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"done"}]}}\n' \
        '{"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info","data":"starting"}}' \
        '{"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info","data":"processing"}}' \
        '{"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info","data":"finished"}}' "$id"
      """#
    let connection = MCPServerConnection(
      config: MCPServerConfig(name: "Burst", command: "/bin/sh", arguments: ["-c", script]),
      workspaceRootURL: try scopedTemporaryDirectory(),
      callToolTimeout: .seconds(3)
    )

    do {
      _ = try await connection.start()
      let result = try await connection.callTool(name: "echo", arguments: [:])
      #expect(result.content == [.text("done")])
      #expect(!result.isError)
      await connection.shutdown()
    } catch {
      await connection.shutdown()
      throw error
    }
  }

  @Test
  func exactLimitFinalFramesRemainAvailableAfterImmediateProcessExit() async throws {
    let process = try await start("printf '%s\\n' '{\"n\":1}' '{\"n\":2}'", frameLimit: 7)
    let result = await process.wait()
    let transport = MCPStdioTransport(process: process, onReceiveEnded: {})
    let stream = await transport.receive()
    var iterator = stream.makeAsyncIterator()

    #expect(result.termination == .exited(0))
    #expect(try await iterator.next() == Data("{\"n\":1}".utf8))
    #expect(try await iterator.next() == Data("{\"n\":2}".utf8))
    await #expect(throws: MCPError.connectionClosed) {
      _ = try await iterator.next()
    }
  }

  @Test(arguments: [true, false])
  func oneByteOverFrameLimitFailsEvenWhenProcessImmediatelyExits(newline: Bool) async throws {
    let format = newline ? "%s\\n" : "%s"
    let process = try await start("printf '\(format)' '{\"n\":10}'", frameLimit: 7)
    let result = await process.wait()

    guard case .failed(.resourceLimit(let message)) = result.termination else {
      Issue.record("Expected an eight-byte frame to exceed the seven-byte allowance")
      return
    }
    #expect(message.contains("frame exceeded"))
    await #expect(throws: OwnedProcess.Failure.self) {
      _ = try await process.nextFrame()
    }
  }

  @Test
  func unterminatedFinalFrameFailsInsteadOfDeliveringPartialJSON() async throws {
    let process = try await start("printf '%s' '{\"n\":1'", frameLimit: 7)
    let result = await process.wait()

    guard case .failed(.io(let message)) = result.termination else {
      Issue.record("Expected incomplete framing to survive the child's exit status")
      return
    }
    #expect(message.contains("newline-delimited frame"))
    await #expect(throws: OwnedProcess.Failure.self) {
      _ = try await process.nextFrame()
    }
  }

  @Test
  func concurrentWritesPreserveWholeMessagesAcrossPipeBackpressure() async throws {
    let process = try await start(
      """
      /usr/bin/awk '{
        if ($0 ~ /^A+$/) kind="A"; else if ($0 ~ /^B+$/) kind="B"; else kind="mixed";
        printf "%s %d\\n", kind, length($0);
        fflush();
        if (NR == 2) exit;
      }'
      """
    )
    let transport = MCPStdioTransport(process: process, onReceiveEnded: {})
    try await transport.connect()

    async let first: Void = transport.send(Data(repeating: 65, count: 262_144))
    async let second: Void = transport.send(Data(repeating: 66, count: 262_144))
    _ = try await (first, second)
    let result = await process.wait()
    let stream = await transport.receive()
    var iterator = stream.makeAsyncIterator()
    let firstReply = try #require(try await iterator.next())
    let secondReply = try #require(try await iterator.next())

    #expect(result.termination == .exited(0))
    #expect(
      Set([firstReply, secondReply]) == [Data("A 262144".utf8), Data("B 262144".utf8)]
    )
  }

  @Test
  func thirdBlockedWriteFailsAndUnblocksTheOtherWriters() async throws {
    let process = try await start("exec /bin/sleep 30")
    let transport = MCPStdioTransport(process: process, onReceiveEnded: {})
    try await transport.connect()
    let message = Data(repeating: 65, count: 2 * 1024 * 1024)
    let began = ContinuousClock.now

    let failures = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
      for _ in 0..<3 {
        group.addTask {
          do {
            try await transport.send(message)
            return false
          } catch is OwnedProcess.Failure {
            return true
          } catch {
            return false
          }
        }
      }
      var results: [Bool] = []
      for await result in group { results.append(result) }
      return results
    }
    let result = await process.wait()

    #expect(failures == [true, true, true])
    #expect(ContinuousClock.now - began < .seconds(5))
    guard case .failed(.resourceLimit) = result.termination else {
      Issue.record("Expected concurrent writes to fail at the two-write allowance")
      return
    }
  }

  @Test
  func toolCallDeadlineClosesBlockedStdioWithoutWaitingForCancellationNotification() async throws {
    let script = """
      request_id() {
        printf '%s\\n' "$1" | sed -E 's/.*"id":("[^"]*"|[0-9]+).*/\\1/'
      }
      read -r line
      id=$(request_id "$line")
      printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"blocked","version":"1.0"}}}\\n' "$id"
      read -r line
      read -r line
      id=$(request_id "$line")
      printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"dump","inputSchema":{"type":"object"}}]}}\\n' "$id"
      exec /bin/sleep 30
      """
    let config = MCPServerConfig(name: "Blocked", command: "/bin/sh", arguments: ["-c", script])
    let manager = MCPClientManager { config, workspaceRootURL in
      MCPServerConnection(
        config: config,
        workspaceRootURL: workspaceRootURL,
        callToolTimeout: .milliseconds(100)
      )
    }
    await manager.reconcile(
      configs: [config],
      activeSessionID: UUID(),
      selectedServerIDs: [config.id],
      workspaceRootURL: try scopedTemporaryDirectory()
    )
    let token = try #require(await manager.connectionToken(for: config.id))
    let began = ContinuousClock.now

    await #expect(throws: MCPClientError.timedOut(method: "tools/call")) {
      _ = try await manager.callTool(
        serverID: config.id,
        connectionToken: token,
        name: "dump",
        arguments: ["text": .string(String(repeating: "x", count: 2 * 1024 * 1024))]
      )
    }
    #expect(ContinuousClock.now - began < .seconds(5))
    #expect(await manager.agentToolExecutors().isEmpty)
    guard case .failed(let message)? = await manager.statuses().first?.state else {
      Issue.record("Expected timed-out stdio connection to be invalidated")
      await manager.shutdownAll()
      return
    }
    #expect(message.contains("tools/call"))
    await manager.shutdownAll()
  }

  private func start(
    _ script: String, frameLimit: Int = 128, timeout: Duration? = nil
  ) async throws -> OwnedProcess {
    try await OwnedProcess.start(
      executableURL: URL(filePath: "/bin/sh"),
      arguments: ["-c", script],
      environment: ProcessInfo.processInfo.environment,
      workingDirectoryURL: try scopedTemporaryDirectory(),
      stdout: .frames(maxBytes: frameLimit, queuedFrames: 2),
      stderrLimit: 1_024,
      timeout: timeout
    )
  }
}
