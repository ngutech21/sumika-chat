import Foundation
import Testing

@testable import SumikaCore

/// End-to-end tests speak real JSON-RPC over stdio against a `/bin/sh` fake
/// server. The client assigns request IDs sequentially starting at 1
/// (initialize = 1, tools/list = 2, first tools/call = 3), which the scripted
/// responses rely on.
struct MCPClientTests {
  private static let fakeServerScript = """
    #!/bin/sh
    read -r line
    printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"fake","version":"1.0"}}}'
    read -r line
    read -r line
    printf '%s\\n' '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"echo","description":"Echo text back.","inputSchema":{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}}]}}'
    read -r line
    printf '%s\\n' '{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"echoed"}],"isError":false}}'
    read -r line
    """

  private func writeScript(_ content: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "sumika-mcp-client-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "fake-mcp-server.sh", directoryHint: .notDirectory)
    try content.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: url.path(percentEncoded: false)
    )
    return url
  }

  private func removeScript(_ url: URL) {
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
  }

  // MARK: - Connection end to end

  @Test
  func startListsToolsAndCallToolRoundTrips() async throws {
    let script = try writeScript(Self.fakeServerScript)
    defer { removeScript(script) }
    let config = MCPServerConfig(
      name: "Fake",
      command: script.path(percentEncoded: false)
    )
    let connection = MCPServerConnection(config: config)

    let tools = try await connection.start()
    let result = try await connection.callTool(
      name: "echo",
      arguments: ["text": .string("hi")]
    )
    await connection.shutdown()

    #expect(tools.count == 1)
    #expect(tools.first?.name == "echo")
    #expect(tools.first?.description == "Echo text back.")
    guard case .object(let schemaFields)? = tools.first?.inputSchema else {
      Issue.record("Expected inputSchema object")
      return
    }
    #expect(schemaFields["required"] == .array([.string("text")]))
    #expect(result.content == [.text("echoed")])
    #expect(!result.isError)
  }

  @Test
  func exitingServerFailsStartWithStderrDetail() async throws {
    let script = try writeScript(
      """
      #!/bin/sh
      echo "fatal: missing token" >&2
      exit 1
      """
    )
    defer { removeScript(script) }
    let connection = MCPServerConnection(
      config: MCPServerConfig(name: "Broken", command: script.path(percentEncoded: false))
    )

    do {
      _ = try await connection.start()
      Issue.record("Expected start() to throw")
    } catch let error as MCPClientError {
      guard case .serverExited(let detail) = error else {
        Issue.record("Expected serverExited, got \(error)")
        return
      }
      #expect(detail?.contains("missing token") == true)
    }
    await connection.shutdown()
  }

  /// Opt-in end-to-end check against the reference server. Requires network
  /// and node; run with `SUMIKA_MCP_E2E=1 xcrun swift test --filter realServer`.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["SUMIKA_MCP_E2E"] == "1"))
  func realServerRoundTripAgainstEverythingServer() async throws {
    let config = MCPServerConfig(
      name: "Everything",
      command: "npx",
      arguments: ["-y", "@modelcontextprotocol/server-everything"]
    )
    let connection = MCPServerConnection(config: config)

    let tools = try await connection.start()
    let result = try await connection.callTool(
      name: "echo",
      arguments: ["message": .string("sumika-e2e")]
    )
    await connection.shutdown()

    #expect(tools.contains { $0.name == "echo" })
    #expect(!result.isError)
    guard case .text(let text)? = result.content.first else {
      Issue.record("Expected text content, got \(result.content)")
      return
    }
    #expect(text.contains("sumika-e2e"))
  }

  // MARK: - Result mapping

  @Test
  func toolResultMapsContentBlocksAndErrorFlag() {
    let result = MCPServerConnection.toolResult(
      from: .object([
        "content": .array([
          .object(["type": .string("text"), "text": .string("first")]),
          .object(["type": .string("image"), "data": .string("...")]),
          .object(["type": .string("text"), "text": .string("second")]),
        ]),
        "isError": .bool(true),
      ]),
      serverName: "Fake",
      remoteToolName: "echo"
    )

    #expect(result.content == [.text("first"), .unsupported(type: "image"), .text("second")])
    #expect(result.isError)
    #expect(!result.truncated)
  }

  @Test
  func toolResultFallsBackToStructuredContent() {
    let result = MCPServerConnection.toolResult(
      from: .object([
        "content": .array([]),
        "structuredContent": .object(["count": .number(3)]),
      ]),
      serverName: "Fake",
      remoteToolName: "stats"
    )

    guard case .text(let text)? = result.content.first else {
      Issue.record("Expected text block, got \(result.content)")
      return
    }
    #expect(text.contains("\"count\""))
  }

  @Test
  func toolResultCapsOversizedText() {
    let oversized = String(repeating: "x", count: 100_000)

    let result = MCPServerConnection.toolResult(
      from: .object([
        "content": .array([
          .object(["type": .string("text"), "text": .string(oversized)])
        ])
      ]),
      serverName: "Fake",
      remoteToolName: "dump"
    )

    guard case .text(let text)? = result.content.first else {
      Issue.record("Expected text block")
      return
    }
    #expect(text.count == 64_000)
    #expect(result.truncated)
  }

  // MARK: - Manager

  @Test
  func managerConnectsAndProjectsExecutors() async throws {
    let script = try writeScript(Self.fakeServerScript)
    defer { removeScript(script) }
    let config = MCPServerConfig(name: "Fake", command: script.path(percentEncoded: false))
    let manager = MCPClientManager()

    await manager.applyConfiguration([config])
    let statuses = await manager.statuses()
    let executors = await manager.agentToolExecutors()
    await manager.shutdownAll()

    #expect(statuses.count == 1)
    #expect(statuses.first?.state == .connected(toolCount: 1))
    #expect(executors.count == 1)
    #expect(executors.first?.definition.name.rawValue == "mcp__fake__echo")
    #expect(executors.first?.definition.rawParametersSchema != nil)
  }

  @Test
  func managerIgnoresStaleConnectionAfterServerIsDisabledDuringStart() async throws {
    let marker = FileManager.default.temporaryDirectory
      .appending(path: "sumika-mcp-start-marker-\(UUID().uuidString)", directoryHint: .notDirectory)
    defer { try? FileManager.default.removeItem(at: marker) }
    defer { try? Data().write(to: marker) }
    let script = try writeScript(
      """
      #!/bin/sh
      marker="$1"
      while [ ! -f "$marker" ]; do
        sleep 0.02
      done
      read -r line
      printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"slow","version":"1.0"}}}'
      read -r line
      read -r line
      printf '%s\\n' '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"echo","description":"Echo text back.","inputSchema":{"type":"object"}}]}}'
      """
    )
    defer { removeScript(script) }
    let config = MCPServerConfig(
      name: "Slow",
      command: script.path(percentEncoded: false),
      arguments: [marker.path(percentEncoded: false)]
    )
    let disabled = MCPServerConfig(
      id: config.id,
      name: config.name,
      command: config.command,
      arguments: config.arguments,
      environment: config.environment,
      isEnabled: false
    )
    let manager = MCPClientManager()

    let startTask = Task {
      await manager.applyConfiguration([config])
    }
    try await waitUntil {
      let statuses = await manager.statuses()
      return statuses.first?.state == .connecting
    }
    await manager.applyConfiguration([disabled])
    try Data().write(to: marker)
    await startTask.value
    let statuses = await manager.statuses()
    let executors = await manager.agentToolExecutors()
    await manager.shutdownAll()

    #expect(statuses.count == 1)
    #expect(statuses.first?.state == .disconnected)
    #expect(executors.isEmpty)
  }

  @Test
  func managerReportsFailureForBrokenServer() async throws {
    let script = try writeScript(
      """
      #!/bin/sh
      exit 7
      """
    )
    defer { removeScript(script) }
    let config = MCPServerConfig(name: "Broken", command: script.path(percentEncoded: false))
    let manager = MCPClientManager()

    await manager.applyConfiguration([config])
    let statuses = await manager.statuses()
    let executors = await manager.agentToolExecutors()
    await manager.shutdownAll()

    guard case .failed? = statuses.first?.state else {
      Issue.record("Expected failed state, got \(String(describing: statuses.first?.state))")
      return
    }
    #expect(executors.isEmpty)
  }

  @Test
  func managerSkipsDisabledServersAndDeduplicatesSlugs() async throws {
    let script = try writeScript(Self.fakeServerScript)
    defer { removeScript(script) }
    let enabled = MCPServerConfig(name: "Twin", command: script.path(percentEncoded: false))
    let enabledTwin = MCPServerConfig(name: "Twin", command: script.path(percentEncoded: false))
    let disabled = MCPServerConfig(
      name: "Off", command: script.path(percentEncoded: false), isEnabled: false)
    let manager = MCPClientManager()

    await manager.applyConfiguration([enabled, enabledTwin, disabled])
    let statuses = await manager.statuses()
    let executors = await manager.agentToolExecutors()
    await manager.shutdownAll()

    #expect(statuses.count == 3)
    #expect(statuses.last?.state == .disconnected)
    #expect(
      executors.map(\.definition.name.rawValue).sorted() == [
        "mcp__twin_2__echo", "mcp__twin__echo",
      ])
  }

  @Test
  func managerRemovesConnectionsForDeletedServers() async throws {
    let script = try writeScript(Self.fakeServerScript)
    defer { removeScript(script) }
    let config = MCPServerConfig(name: "Fake", command: script.path(percentEncoded: false))
    let manager = MCPClientManager()

    await manager.applyConfiguration([config])
    await manager.applyConfiguration([])
    let statuses = await manager.statuses()
    let executors = await manager.agentToolExecutors()
    await manager.shutdownAll()

    #expect(statuses.isEmpty)
    #expect(executors.isEmpty)
  }
}

private func waitUntil(
  timeout: Duration = .seconds(1),
  condition: @escaping @Sendable () async -> Bool
) async throws {
  let start = ContinuousClock.now
  while !(await condition()) {
    if ContinuousClock.now - start > timeout {
      Issue.record("Timed out waiting for condition")
      throw MCPClientTestWaitTimeoutError()
    }
    try await Task.sleep(for: .milliseconds(10))
  }
}

private struct MCPClientTestWaitTimeoutError: Error {}
