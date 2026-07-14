import Foundation
import MCP
import Testing

@testable import SumikaCore

/// End-to-end tests speak real JSON-RPC over stdio against a `/bin/sh` fake
/// server. The SDK uses opaque request IDs, so scripted responses echo each
/// request's ID instead of assuming a sequence.
struct MCPClientTests {
  private static let fakeServerScript = """
    #!/bin/sh
    request_id() {
      printf '%s\\n' "$1" | sed -E 's/.*"id":("[^"]*"|[0-9]+).*/\\1/'
    }
    read -r line
    id=$(request_id "$line")
    printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"fake","version":"1.0"}}}\\n' "$id"
    read -r line
    read -r line
    id=$(request_id "$line")
    printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"echo","description":"Echo text back.","inputSchema":{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}}]}}\\n' "$id"
    read -r line
    id=$(request_id "$line")
    printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"echoed"}],"isError":false}}\\n' "$id"
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
    let connection = MCPServerConnection(
      config: config,
      workspaceRootURL: script.deletingLastPathComponent()
    )

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
  func streamableHTTPUsesInjectedTransportAndListsAndCallsTools() async throws {
    let endpoint = try #require(URL(string: "http://127.0.0.1:8080/mcp"))

    let roundTrip = try await injectedHTTPRoundTrip(endpoint: endpoint)

    #expect(roundTrip.tools.map(\.name) == ["echo"])
    #expect(roundTrip.result.content == [.text("echoed-http")])
    #expect(roundTrip.advertisedRoots)
  }

  @Test
  func remoteStreamableHTTPDoesNotAdvertiseWorkspaceRoots() async throws {
    let endpoint = try #require(URL(string: "https://mcp.example.com/mcp"))

    let roundTrip = try await injectedHTTPRoundTrip(endpoint: endpoint)

    #expect(roundTrip.tools.map(\.name) == ["echo"])
    #expect(!roundTrip.advertisedRoots)
  }

  private func injectedHTTPRoundTrip(
    endpoint: URL
  ) async throws -> (tools: [MCPRemoteTool], result: MCPToolResult, advertisedRoots: Bool) {
    let transports = await InMemoryTransport.createConnectedPair()
    let capabilityRecorder = MCPRootsCapabilityRecorder()
    let server = try await startInMemoryServer(
      transport: transports.server,
      capabilityRecorder: capabilityRecorder
    )

    let connection = MCPServerConnection(
      config: MCPServerConfig(
        name: "HTTP test",
        transport: .streamableHTTP(endpoint: endpoint)
      ),
      workspaceRootURL: FileManager.default.temporaryDirectory,
      makeHTTPTransport: { _ in transports.client }
    )
    let tools = try await connection.start()
    let result = try await connection.callTool(name: "echo", arguments: ["text": .string("hi")])
    let advertisedRoots = await capabilityRecorder.advertisedRoots
    await connection.shutdown()
    await server.stop()
    return (tools, result, advertisedRoots)
  }

  private func startInMemoryServer(
    transport: InMemoryTransport,
    toolName: String = "echo",
    capabilityRecorder: MCPRootsCapabilityRecorder? = nil
  ) async throws -> Server {
    let server = Server(
      name: "HTTP test server",
      version: "1.0",
      capabilities: .init(tools: .init())
    )
    await server.withMethodHandler(ListTools.self) { _ in
      ListTools.Result(tools: [
        Tool(
          name: toolName,
          description: "Echo text back.",
          inputSchema: [
            "type": "object",
            "properties": ["text": ["type": "string"]],
            "required": ["text"],
          ]
        )
      ])
    }
    await server.withMethodHandler(CallTool.self) { request in
      CallTool.Result(
        content: [
          .text(
            text: request.name == toolName ? "echoed-http" : "unexpected",
            annotations: nil,
            _meta: nil
          )
        ],
        isError: request.name == toolName ? false : true
      )
    }
    try await server.start(transport: transport) { _, capabilities in
      await capabilityRecorder?.record(advertisedRoots: capabilities.roots != nil)
    }
    return server
  }

  @Test
  func connectionUsesWorkspaceDirectoryAndAnswersRootsList() async throws {
    let workspaceRootURL = FileManager.default.temporaryDirectory.appending(
      path: "sumika-mcp-workspace-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: workspaceRootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspaceRootURL) }
    let resolvedWorkspaceRootURL = workspaceRootURL.resolvingSymlinksInPath()
    try Data().write(to: workspaceRootURL.appending(path: ".workspace-root-marker"))
    let markerURL = workspaceRootURL.appending(path: "roots-response.json")
    let script = try writeScript(
      """
      #!/bin/sh
      request_id() {
        printf '%s\\n' "$1" | sed -E 's/.*"id":("[^"]*"|[0-9]+).*/\\1/'
      }
      marker="$1"
      [ -f .workspace-root-marker ] || { echo "wrong cwd: $PWD" >&2; exit 8; }
      read -r line
      id=$(request_id "$line")
      printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"roots","version":"1.0"}}}\\n' "$id"
      read -r line
      printf '%s\\n' '{"jsonrpc":"2.0","id":"root-request","method":"roots/list"}'
      read -r first
      read -r second
      case "$first" in
        *'"id":"root-request"'*) roots_response="$first"; list_request="$second" ;;
        *) roots_response="$second"; list_request="$first" ;;
      esac
      printf '%s\\n' "$roots_response" > "$marker"
      id=$(request_id "$list_request")
      printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[]}}\\n' "$id"
      """
    )
    defer { removeScript(script) }
    let connection = MCPServerConnection(
      config: MCPServerConfig(
        name: "Roots",
        command: script.path(percentEncoded: false),
        arguments: [markerURL.path(percentEncoded: false)]
      ),
      workspaceRootURL: workspaceRootURL
    )

    let tools = try await connection.start()
    await connection.shutdown()

    #expect(tools.isEmpty)
    let response = try JSONDecoder().decode(
      ToolArgumentValue.self,
      from: Data(contentsOf: markerURL)
    )
    guard case .object(let fields) = response,
      case .object(let result)? = fields["result"],
      case .array(let roots)? = result["roots"],
      case .object(let root)? = roots.first
    else {
      Issue.record("Expected roots/list response")
      return
    }
    #expect(root["uri"] == .string(resolvedWorkspaceRootURL.absoluteString))
    #expect(root["name"] == nil)
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
      config: MCPServerConfig(name: "Broken", command: script.path(percentEncoded: false)),
      workspaceRootURL: script.deletingLastPathComponent()
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
    let connection = MCPServerConnection(
      config: config,
      workspaceRootURL: FileManager.default.temporaryDirectory
    )

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
      from: CallTool.Result(
        content: [
          .text(text: "first", annotations: nil, _meta: nil),
          .image(data: "...", mimeType: "image/png", annotations: nil, _meta: nil),
          .text(text: "second", annotations: nil, _meta: nil),
        ],
        isError: true
      ),
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
      from: CallTool.Result(
        structuredContent: .object(["count": .int(3)])
      ),
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
      from: CallTool.Result(
        content: [.text(text: oversized, annotations: nil, _meta: nil)]
      ),
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
  func managerDoesNotStartServersWhenConfigurationIsOnlyLoaded() async throws {
    let script = try writeScript(Self.fakeServerScript)
    defer { removeScript(script) }
    let config = MCPServerConfig(name: "Lazy", command: script.path(percentEncoded: false))
    let manager = MCPClientManager()

    await manager.applyConfiguration([config])

    #expect(await manager.statuses().first?.state == .disconnected)
    #expect(await manager.agentToolExecutors().isEmpty == true)
  }

  @Test
  func managerStartsOnlySelectedServersForActiveSession() async throws {
    let script = try writeScript(Self.fakeServerScript)
    defer { removeScript(script) }
    let first = MCPServerConfig(name: "First", command: script.path(percentEncoded: false))
    let second = MCPServerConfig(name: "Second", command: script.path(percentEncoded: false))
    let manager = MCPClientManager()

    await activate(manager, configs: [first, second], selectedServerIDs: [second.id])
    let statuses = await manager.statuses()
    let groups = await manager.agentToolExecutorGroups()
    await manager.shutdownAll()

    #expect(statuses.map(\.state) == [.disconnected, .connected(toolCount: 1)])
    #expect(groups.map(\.serverID) == [second.id])
  }

  @Test
  func managerConnectsAndProjectsExecutors() async throws {
    let script = try writeScript(Self.fakeServerScript)
    defer { removeScript(script) }
    let config = MCPServerConfig(name: "Fake", command: script.path(percentEncoded: false))
    let manager = MCPClientManager()

    await activate(manager, configs: [config])
    let statuses = await manager.statuses()
    let executors = await manager.agentToolExecutors()
    let groups = await manager.agentToolExecutorGroups()
    await manager.shutdownAll()

    #expect(statuses.count == 1)
    #expect(statuses.first?.state == .connected(toolCount: 1))
    #expect(executors.count == 1)
    #expect(executors.first?.definition.name.rawValue == "mcp__fake__echo")
    #expect(executors.first?.definition.rawParametersSchema != nil)
    #expect(groups.map(\.serverID) == [config.id])
    #expect(groups.first?.executors.map(\.definition.name.rawValue) == ["mcp__fake__echo"])
  }

  @Test
  func managerRestartsAndRenamesToolsWhenServerNameChanges() async throws {
    let script = try writeScript(Self.fakeServerScript)
    defer { removeScript(script) }
    let original = MCPServerConfig(name: "Original", command: script.path(percentEncoded: false))
    let renamed = MCPServerConfig(
      id: original.id,
      name: "Renamed",
      transport: original.transport
    )
    let sessionID = UUID()
    let manager = MCPClientManager()

    await activate(manager, configs: [original], sessionID: sessionID)
    let originalToken = try #require(await manager.connectionToken(for: original.id))
    await activate(manager, configs: [renamed], sessionID: sessionID)
    let renamedToken = try #require(await manager.connectionToken(for: renamed.id))
    let executors = await manager.agentToolExecutors()
    await manager.shutdownAll()

    #expect(originalToken != renamedToken)
    #expect(executors.map(\.definition.name.rawValue) == ["mcp__renamed__echo"])
  }

  @Test
  func managerRestartsWhenHTTPTransportEndpointChanges() async throws {
    let firstEndpoint = try #require(URL(string: "http://127.0.0.1:8080/mcp"))
    let secondEndpoint = try #require(URL(string: "http://127.0.0.1:8081/mcp"))
    let firstTransports = await InMemoryTransport.createConnectedPair()
    let secondTransports = await InMemoryTransport.createConnectedPair()
    let firstServer = try await startInMemoryServer(
      transport: firstTransports.server,
      toolName: "first"
    )
    let secondServer = try await startInMemoryServer(
      transport: secondTransports.server,
      toolName: "second"
    )
    let clientTransports = [
      firstEndpoint.absoluteString: firstTransports.client,
      secondEndpoint.absoluteString: secondTransports.client,
    ]
    let manager = MCPClientManager { config, workspaceRootURL in
      guard case .streamableHTTP(let endpoint) = config.transport,
        let transport = clientTransports[endpoint.absoluteString]
      else {
        preconditionFailure("Unexpected MCP test configuration")
      }
      return MCPServerConnection(
        config: config,
        workspaceRootURL: workspaceRootURL,
        makeHTTPTransport: { _ in transport }
      )
    }
    let firstConfig = MCPServerConfig(
      name: "Remote",
      transport: .streamableHTTP(endpoint: firstEndpoint)
    )
    let secondConfig = MCPServerConfig(
      id: firstConfig.id,
      name: firstConfig.name,
      transport: .streamableHTTP(endpoint: secondEndpoint)
    )
    let sessionID = UUID()

    await activate(manager, configs: [firstConfig], sessionID: sessionID)
    let firstToken = try #require(await manager.connectionToken(for: firstConfig.id))
    #expect(
      await manager.agentToolExecutors().map(\.definition.name.rawValue)
        == ["mcp__remote__first"]
    )

    await activate(manager, configs: [secondConfig], sessionID: sessionID)
    let secondToken = try #require(await manager.connectionToken(for: secondConfig.id))
    let secondToolNames = await manager.agentToolExecutors().map(\.definition.name.rawValue)
    await manager.shutdownAll()
    await firstServer.stop()
    await secondServer.stop()

    #expect(firstToken != secondToken)
    #expect(secondToolNames == ["mcp__remote__second"])
  }

  @Test
  func managerClearsAdvertisedToolsWhenConnectedServerExits() async throws {
    let script = try writeScript(
      """
      #!/bin/sh
      request_id() {
        printf '%s\\n' "$1" | sed -E 's/.*"id":("[^"]*"|[0-9]+).*/\\1/'
      }
      read -r line
      id=$(request_id "$line")
      printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"fake","version":"1.0"}}}\\n' "$id"
      read -r line
      read -r line
      id=$(request_id "$line")
      printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"echo","description":"Echo text back.","inputSchema":{"type":"object"}}]}}\\n' "$id"
      echo "fatal: crashed after listing tools" >&2
      exit 9
      """
    )
    defer { removeScript(script) }
    let config = MCPServerConfig(name: "Crashy", command: script.path(percentEncoded: false))
    let manager = MCPClientManager()

    await activate(manager, configs: [config])
    #expect(await manager.statuses().first?.state == .connected(toolCount: 1))
    #expect(await manager.agentToolExecutors().count == 1)

    do {
      let connectionToken = try #require(await manager.connectionToken(for: config.id))
      _ = try await manager.callTool(
        serverID: config.id,
        connectionToken: connectionToken,
        name: "echo",
        arguments: [:]
      )
      Issue.record("Expected callTool() to throw")
    } catch let error as MCPClientError {
      switch error {
      case .notConnected, .serverExited:
        break
      case .staleConnection, .timedOut, .protocolError, .serverError:
        Issue.record("Expected connection lifecycle error, got \(error)")
      }
    } catch {
      Issue.record("Expected MCPClientError, got \(error)")
    }

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
  func managerIgnoresStaleConnectionAfterServerIsDisabledDuringStart() async throws {
    let marker = FileManager.default.temporaryDirectory
      .appending(path: "sumika-mcp-start-marker-\(UUID().uuidString)", directoryHint: .notDirectory)
    defer { try? FileManager.default.removeItem(at: marker) }
    defer { try? Data().write(to: marker) }
    let script = try writeScript(
      """
      #!/bin/sh
      request_id() {
        printf '%s\\n' "$1" | sed -E 's/.*"id":("[^"]*"|[0-9]+).*/\\1/'
      }
      marker="$1"
      while [ ! -f "$marker" ]; do
        sleep 0.02
      done
      read -r line
      id=$(request_id "$line")
      printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"slow","version":"1.0"}}}\\n' "$id"
      read -r line
      read -r line
      id=$(request_id "$line")
      printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"echo","description":"Echo text back.","inputSchema":{"type":"object"}}]}}\\n' "$id"
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
      transport: config.transport,
      isEnabled: false
    )
    let manager = MCPClientManager()

    let startTask = Task {
      await activate(manager, configs: [config])
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

    await activate(manager, configs: [config])
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

    await activate(manager, configs: [enabled, enabledTwin, disabled])
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

    await activate(manager, configs: [config])
    await manager.applyConfiguration([])
    let statuses = await manager.statuses()
    let executors = await manager.agentToolExecutors()
    await manager.shutdownAll()

    #expect(statuses.isEmpty)
    #expect(executors.isEmpty)
  }

  @Test
  func managerRejectsExecutorTokenAfterReconnect() async throws {
    let script = try writeScript(Self.fakeServerScript)
    defer { removeScript(script) }
    let config = MCPServerConfig(name: "Token", command: script.path(percentEncoded: false))
    let manager = MCPClientManager()
    await activate(manager, configs: [config])
    let oldToken = try #require(await manager.connectionToken(for: config.id))

    await manager.reconnect(serverID: config.id)
    let newToken = try #require(await manager.connectionToken(for: config.id))

    #expect(oldToken != newToken)
    await #expect(throws: MCPClientError.staleConnection) {
      _ = try await manager.callTool(
        serverID: config.id,
        connectionToken: oldToken,
        name: "echo",
        arguments: [:]
      )
    }
    await manager.shutdownAll()
  }

  @Test
  func settingsProbeDoesNotActivateConfiguredServer() async throws {
    let script = try writeScript(Self.fakeServerScript)
    defer { removeScript(script) }
    let config = MCPServerConfig(name: "Probe", command: script.path(percentEncoded: false))
    let manager = MCPClientManager()
    await manager.applyConfiguration([config])

    let toolCount = try await manager.testConnection(
      config: config,
      workspaceRootURL: FileManager.default.temporaryDirectory
    )

    #expect(toolCount == 1)
    #expect(await manager.statuses().first?.state == .disconnected)
    #expect(await manager.agentToolExecutors().isEmpty == true)
  }
}

private func activate(
  _ manager: MCPClientManager,
  configs: [MCPServerConfig],
  sessionID: ChatSession.ID = UUID(),
  selectedServerIDs: [UUID]? = nil,
  workspaceRootURL: URL = FileManager.default.temporaryDirectory
) async {
  await manager.reconcile(
    configs: configs,
    activeSessionID: sessionID,
    selectedServerIDs: selectedServerIDs ?? configs.map(\.id),
    workspaceRootURL: workspaceRootURL
  )
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

private actor MCPRootsCapabilityRecorder {
  private(set) var advertisedRoots = false

  func record(advertisedRoots: Bool) {
    self.advertisedRoots = advertisedRoots
  }
}
