import Darwin
import Foundation
import Logging
import MCP
import SumikaTestSupport
import Synchronization
import Testing

@testable import SumikaCore

/// End-to-end tests speak real JSON-RPC over stdio against a `/bin/sh` fake
/// server. The SDK uses opaque request IDs, so scripted responses echo each
/// request's ID instead of assuming a sequence.
@Suite(TemporaryDirectoryTrait(named: "sumika-mcp-client-tests"))
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
    let directory = try scopedTemporaryDirectory()
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "fake-mcp-server.sh", directoryHint: .notDirectory)
    try content.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: url.path(percentEncoded: false)
    )
    return url
  }

  // MARK: - Connection end to end

  @Test
  func startListsToolsAndCallToolRoundTrips() async throws {
    let script = try writeScript(Self.fakeServerScript)
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
    let workspaceRootURL = try scopedTemporaryDirectory().appending(
      path: UUID().uuidString,
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: workspaceRootURL, withIntermediateDirectories: true)
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

  @Test
  func oversizedUnterminatedFrameFailsInitializationBeforeTimeout() async throws {
    let script = try writeScript(
      """
      #!/bin/sh
      dd if=/dev/zero bs=1048576 count=9 2>/dev/null | tr '\\000' x
      sleep 30
      """
    )
    let connection = MCPServerConnection(
      config: MCPServerConfig(name: "Oversized", command: script.path(percentEncoded: false)),
      workspaceRootURL: script.deletingLastPathComponent()
    )
    let start = ContinuousClock.now

    do {
      _ = try await connection.start()
      Issue.record("Expected oversized frame to fail initialization")
    } catch let error as MCPClientError {
      guard case .resourceLimit = error else {
        Issue.record("Expected resource limit error, got \(error)")
        await connection.shutdown()
        return
      }
    }
    await connection.shutdown()

    #expect(ContinuousClock.now - start < .seconds(10))
  }

  @Test
  func exitingServerPreservesBoundedStderrTailWithoutNewlines() async throws {
    let script = try writeScript(
      """
      #!/bin/sh
      printf 'discard-this-prefix:' >&2
      dd if=/dev/zero bs=16384 count=1 2>/dev/null | tr '\\000' x >&2
      printf ':final-diagnostic' >&2
      exit 1
      """
    )
    let connection = MCPServerConnection(
      config: MCPServerConfig(name: "Verbose", command: script.path(percentEncoded: false)),
      workspaceRootURL: script.deletingLastPathComponent()
    )

    do {
      _ = try await connection.start()
      Issue.record("Expected server exit")
    } catch let error as MCPClientError {
      guard case .serverExited(let detail) = error else {
        Issue.record("Expected stderr diagnostic on server exit, got \(error)")
        await connection.shutdown()
        return
      }
      #expect(detail?.hasSuffix(":final-diagnostic") == true)
      #expect(detail?.contains("discard-this-prefix") == false)
      #expect(detail?.utf8.count == 8_192)
    }
    await connection.shutdown()
  }

  @Test
  func closedStdoutFailsInitializationWithoutWaitingForProcessExit() async throws {
    let script = try writeScript(
      """
      #!/bin/sh
      exec 1>&-
      sleep 30
      """
    )
    let connection = MCPServerConnection(
      config: MCPServerConfig(name: "ClosedOutput", command: script.path(percentEncoded: false)),
      workspaceRootURL: script.deletingLastPathComponent()
    )
    let start = ContinuousClock.now

    do {
      _ = try await connection.start()
      Issue.record("Expected closed protocol output to fail initialization")
    } catch let error as MCPClientError {
      guard case .serverExited = error else {
        Issue.record("Expected connection lifecycle error, got \(error)")
        await connection.shutdown()
        return
      }
    }
    await connection.shutdown()

    #expect(ContinuousClock.now - start < .seconds(10))
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

  @Test(arguments: ["uv", "uvx"], [false, true])
  func bundledRuntimePreservesArgumentsAndUsesPrivateEnvironment(
    command: String, overridePython: Bool
  ) async throws {
    let root = try scopedTemporaryDirectory()
    let report = root.appending(path: "launch.txt")
    let script = try writeScript(
      """
      #!/bin/sh
      printf '%s\\n' "$@" "$PWD" "$UV_PYTHON_INSTALL_DIR" "$UV_CACHE_DIR" "$UV_TOOL_DIR" "$UV_MANAGED_PYTHON" "$UV_PYTHON_DOWNLOADS" "${UV_PYTHON-unset}" "${VIRTUAL_ENV-unset}" "$CUSTOM_VALUE" "$UV_OFFLINE" > "$REPORT"
      """ + "\n" + Self.fakeServerScript.replacingOccurrences(of: "| sed ", with: "| /usr/bin/sed ")
    )
    let helper = root.appending(path: "bundled uv")
    try FileManager.default.copyItem(at: script, to: helper)
    let runtime = MCPRuntimeConfiguration(
      uvExecutableURL: helper, dataDirectoryURL: root.appending(path: "runtime data"),
      cacheDirectoryURL: root.appending(path: "runtime cache"))
    var environment = ["PATH": "/nonexistent", "REPORT": report.path, "CUSTOM_VALUE": "explicit"]
    if overridePython {
      environment["UV_PYTHON"] = "3.12"
      let conflictingExecutable = root.appending(path: command)
      try "#!/bin/sh\nexit 99\n".write(
        to: conflictingExecutable, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: conflictingExecutable.path)
      environment["PATH"] = root.path
    }
    let config = MCPServerConfig(
      name: "Managed", command: command, arguments: ["server", "a b", "$(literal)"],
      environment: environment)
    let manager = MCPClientManager { config, root in
      MCPServerConnection(
        config: config, workspaceRootURL: root,
        baseEnvironment: [
          "UV_PYTHON": "/missing/python", "VIRTUAL_ENV": "/missing/venv",
          "UV_PYTHON_INSTALL_DIR": "/wrong", "UV_MANAGED_PYTHON": "0", "UV_OFFLINE": "1",
          "UV_CACHE_DIR": "/wrong", "UV_TOOL_DIR": "/wrong", "UV_PYTHON_DOWNLOADS": "never",
        ],
        runtimeConfiguration: runtime)
    }
    let count = try await manager.testConnection(config: config, workspaceRootURL: root)
    #expect(count == 1)
    var expected =
      (command == "uvx" ? ["tool", "run"] : []) + [
        "server", "a b", "$(literal)", root.resolvingSymlinksInPath().path,
        root.appending(path: "runtime data/python").path,
        root.appending(path: "runtime cache").path, root.appending(path: "runtime data/tools").path,
        "1", "automatic", overridePython ? "3.12" : "unset", "unset", "explicit", "1",
      ]
    var actual = try String(contentsOf: report, encoding: .utf8).split(separator: "\n").map(
      String.init)
    let cwdIndex = command == "uvx" ? 5 : 3
    #expect(
      FileManager.default.contentsEqual(
        atPath: actual[cwdIndex] + "/launch.txt", andPath: report.path))
    actual.remove(at: cwdIndex)
    expected.remove(at: cwdIndex)
    #expect(actual == expected)
    await activate(manager, configs: [config], workspaceRootURL: root)
    #expect(await manager.statuses().first?.state == .connected(toolCount: 1))
    await manager.shutdownAll()
  }

  @Test(arguments: [false, true])
  func missingOrNonexecutableBundledRuntimeFailsWithoutPATHFallback(nonexecutable: Bool)
    async throws
  {
    let root = try scopedTemporaryDirectory()
    let helper = root.appending(path: "uv")
    if nonexecutable { try "not executable".write(to: helper, atomically: true, encoding: .utf8) }
    let connection = MCPServerConnection(
      config: MCPServerConfig(name: "Missing", command: "uv"), workspaceRootURL: root,
      runtimeConfiguration: MCPRuntimeConfiguration(
        uvExecutableURL: helper, dataDirectoryURL: root, cacheDirectoryURL: root))
    await #expect(throws: MCPClientError.bundledRuntimeUnavailable) { try await connection.start() }
  }

  @Test(arguments: [false, true])
  func explicitUVPathDoesNotUseBundledRuntime(relative: Bool) async throws {
    let script = try writeScript(Self.fakeServerScript)
    let root = script.deletingLastPathComponent()
    let helper = root.appending(path: "uv")
    try FileManager.default.copyItem(at: script, to: helper)
    let connection = MCPServerConnection(
      config: MCPServerConfig(name: "External", command: relative ? "./uv" : helper.path),
      workspaceRootURL: root,
      runtimeConfiguration: MCPRuntimeConfiguration(
        uvExecutableURL: root.appending(path: "missing"), dataDirectoryURL: root,
        cacheDirectoryURL: root))
    #expect(try await connection.start().count == 1)
    await connection.shutdown()
  }

  @Test
  func managedStartupDeadlineStopsProcess() async throws {
    let root = try scopedTemporaryDirectory()
    let marker = root.appending(path: "pid")
    let script = try writeScript("#!/bin/sh\necho $$ > \"$MARKER\"\nexec /bin/sleep 60\n")
    let connection = MCPServerConnection(
      config: MCPServerConfig(
        name: "Stalled", command: "uvx", environment: ["MARKER": marker.path]),
      workspaceRootURL: root,
      runtimeConfiguration: MCPRuntimeConfiguration(
        uvExecutableURL: script, dataDirectoryURL: root, cacheDirectoryURL: root),
      initializeTimeout: .seconds(2))
    await #expect(throws: MCPClientError.timedOut(method: "initialize")) {
      try await connection.start()
    }
    let pid = try #require(
      Int32(
        String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
    )
    #expect(kill(pid, 0) == -1 && errno == ESRCH)
  }

  @Test(arguments: [false, true])
  func slowStartupDoesNotBlockAnotherServerAndCancellationStopsProcess(terminate: Bool) async throws
  {
    let root = try scopedTemporaryDirectory()
    let marker = root.appending(path: "pid")
    let stalled = try writeScript("#!/bin/sh\necho $$ > \"$MARKER\"\nexec /bin/sleep 60\n")
    let ready = try writeScript(Self.fakeServerScript)
    let slow = MCPServerConfig(name: "Slow", command: "uvx", environment: ["MARKER": marker.path])
    let fast = MCPServerConfig(name: "Fast", command: ready.path)
    let manager = MCPClientManager(
      runtimeConfiguration: MCPRuntimeConfiguration(
        uvExecutableURL: stalled, dataDirectoryURL: root, cacheDirectoryURL: root))
    let sessionID = UUID()
    await manager.reconcile(
      configs: [slow, fast], activeSessionID: sessionID,
      selectedServerIDs: [slow.id, fast.id], workspaceRootURL: root)
    try await waitUntil(timeout: .seconds(5)) {
      await manager.statuses().last?.state == .connected(toolCount: 1)
    }
    #expect(await manager.statuses().first?.state == .connecting)
    try await waitUntil(timeout: .seconds(5)) {
      FileManager.default.fileExists(atPath: marker.path)
    }
    if terminate {
      await manager.shutdownAll()
    } else {
      await manager.reconcile(
        configs: [slow, fast], activeSessionID: sessionID,
        selectedServerIDs: [fast.id], workspaceRootURL: root)
    }
    #expect(await manager.statuses().first?.state == .disconnected)
    #expect(await manager.agentToolExecutorGroups().map(\.serverID) == (terminate ? [] : [fast.id]))
    let pid = try #require(
      Int32(
        String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
    )
    #expect(kill(pid, 0) == -1 && errno == ESRCH)
    await manager.shutdownAll()
  }

  // MARK: - Manager

  @Test(arguments: [false, true])
  func scopeChangeAndShutdownNeverPublishPartiallyRetiredTools(shutdown: Bool) async throws {
    let script = try writeScript(Self.fakeServerScript)
    let configs = ["First", "Second"].map { MCPServerConfig(name: $0, command: script.path) }
    let manager = MCPClientManager()
    await activate(manager, configs: configs)
    let events = AsyncStream<MCPClientManager.Snapshot>.makeStream()
    await manager.setChangeHandler { events.continuation.yield($0) }
    if shutdown {
      await manager.shutdownAll()
    } else {
      await manager.reconcile(
        configs: configs, activeSessionID: UUID(), selectedServerIDs: [],
        workspaceRootURL: script.deletingLastPathComponent(), revision: 2)
    }
    for await snapshot in events.stream {
      #expect(snapshot.groups.isEmpty)
      #expect(snapshot.statuses.allSatisfy { $0.state == .disconnected })
      break
    }
    events.continuation.finish()
    await manager.shutdownAll()
  }

  @Test
  func managerDoesNotStartServersWhenConfigurationIsOnlyLoaded() async throws {
    let script = try writeScript(Self.fakeServerScript)
    let config = MCPServerConfig(name: "Lazy", command: script.path(percentEncoded: false))
    let manager = MCPClientManager()

    await manager.applyConfiguration([config])

    #expect(await manager.statuses().first?.state == .disconnected)
    #expect(await manager.agentToolExecutors().isEmpty == true)
  }

  @Test
  func managerStartsOnlySelectedServersForActiveSession() async throws {
    let script = try writeScript(Self.fakeServerScript)
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
      read -r line
      echo "fatal: crashed during tool call" >&2
      exit 9
      """
    )
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
      case .staleConnection, .timedOut, .protocolError, .serverError, .resourceLimit,
        .bundledRuntimeUnavailable:
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
  func managerInvalidatesConnectionAfterOversizedToolResponse() async throws {
    let script = try writeScript(
      """
      #!/bin/sh
      request_id() {
        printf '%s\\n' "$1" | sed -E 's/.*"id":("[^"]*"|[0-9]+).*/\\1/'
      }
      read -r line
      id=$(request_id "$line")
      printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"oversized","version":"1.0"}}}\\n' "$id"
      read -r line
      read -r line
      id=$(request_id "$line")
      printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"dump","inputSchema":{"type":"object"}}]}}\\n' "$id"
      read -r line
      dd if=/dev/zero bs=1048576 count=9 2>/dev/null | tr '\\000' x
      printf '\\n'
      sleep 30
      """
    )
    let config = MCPServerConfig(name: "Oversized", command: script.path(percentEncoded: false))
    let manager = MCPClientManager()
    await activate(manager, configs: [config])
    let token = try #require(await manager.connectionToken(for: config.id))
    let start = ContinuousClock.now

    do {
      _ = try await manager.callTool(
        serverID: config.id,
        connectionToken: token,
        name: "dump",
        arguments: [:]
      )
      Issue.record("Expected oversized tool response to fail")
    } catch let error as MCPClientError {
      guard case .resourceLimit = error else {
        Issue.record("Expected resource limit error, got \(error)")
        await manager.shutdownAll()
        return
      }
    }
    let statuses = await manager.statuses()
    let tools = await manager.agentToolExecutors()
    await manager.shutdownAll()

    #expect(ContinuousClock.now - start < .seconds(10))
    #expect(tools.isEmpty)
    guard case .failed(let message)? = statuses.first?.state else {
      Issue.record("Expected resource failure to invalidate the connection")
      return
    }
    #expect(message.contains("limit"))
  }

  @Test
  func managerIgnoresStaleConnectionAfterServerIsDisabledDuringStart() async throws {
    let marker = try scopedTemporaryDirectory()
      .appending(path: "start-marker-\(UUID().uuidString)", directoryHint: .notDirectory)
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

  @Test(arguments: ReconnectRetirementChange.allCases)
  func cancelledReconnectDuringRetirementPreservesCurrentSelection(
    change: ReconnectRetirementChange
  ) async throws {
    let endpoint = try #require(URL(string: "https://mcp.example.com"))
    let first = await InMemoryTransport.createConnectedPair()
    let replacement = await InMemoryTransport.createConnectedPair()
    let firstServer = try await startInMemoryServer(transport: first.server)
    let replacementServer = try await startInMemoryServer(transport: replacement.server)
    let retiringTransport = MCPDisconnectGateTransport(base: first.client)
    let transports = Mutex<[any Transport]>([retiringTransport, replacement.client])
    let manager = MCPClientManager { config, root in
      let transport = transports.withLock { $0.removeFirst() }
      return MCPServerConnection(
        config: config, workspaceRootURL: root, makeHTTPTransport: { _ in transport })
    }
    let config = MCPServerConfig(
      name: "Reconnect", transport: .streamableHTTP(endpoint: endpoint))
    let sessionID = UUID()
    await activate(manager, configs: [config], sessionID: sessionID)
    let oldToken = await manager.connectionToken(for: config.id)

    let reconnect = Task { await manager.reconnect(serverID: config.id) }
    try await waitUntil { await retiringTransport.isDisconnecting }
    reconnect.cancel()
    if change == .deselected {
      await activate(manager, configs: [config], sessionID: sessionID, selectedServerIDs: [])
    }
    await retiringTransport.releaseDisconnect()
    await reconnect.value

    #expect(await manager.connectionToken(for: config.id) != oldToken)
    #expect(await manager.statuses().first?.state == .disconnected)
    #expect(await manager.agentToolExecutorGroups().isEmpty == true)
    if change == .reconciled {
      await activate(manager, configs: [config], sessionID: sessionID)
      #expect(await manager.statuses().first?.state == .disconnected)
    }
    #expect(transports.withLock { $0.count } == 1)

    if transports.withLock({ !$0.isEmpty }) {
      await manager.reconnect(serverID: config.id)
    }
    #expect(
      await manager.statuses().first?.state
        == (change == .deselected ? .disconnected : .connected(toolCount: 1)))
    #expect(transports.withLock { $0.count } == (change == .deselected ? 1 : 0))
    await manager.shutdownAll()
    await firstServer.stop()
    await replacementServer.stop()
  }

  enum ReconnectRetirementChange: CaseIterable, Sendable {
    case unchanged, reconciled, deselected
  }

  @Test
  func settingsProbeDoesNotActivateConfiguredServer() async throws {
    let script = try writeScript(Self.fakeServerScript)
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
  for config in configs {
    await manager.waitForStartup(serverID: config.id)
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

private actor MCPDisconnectGateTransport: Transport {
  nonisolated let logger: Logger
  private let base: InMemoryTransport
  private var incoming: AsyncThrowingStream<Data, any Error>?
  private var disconnectWaiters: [CheckedContinuation<Void, Never>] = []
  private var isReleased = false
  private(set) var isDisconnecting = false

  init(base: InMemoryTransport) {
    self.base = base
    self.logger = base.logger
  }

  func connect() async throws {
    try await base.connect()
    incoming = await base.receive()
  }

  func send(_ data: Data) async throws {
    try await base.send(data)
  }

  func receive() -> AsyncThrowingStream<Data, any Error> {
    incoming ?? AsyncThrowingStream { $0.finish() }
  }

  func disconnect() async {
    isDisconnecting = true
    if !isReleased {
      await withCheckedContinuation { disconnectWaiters.append($0) }
    }
    await base.disconnect()
  }

  func releaseDisconnect() {
    isReleased = true
    for waiter in disconnectWaiters { waiter.resume() }
    disconnectWaiters.removeAll()
  }
}

private actor MCPRootsCapabilityRecorder {
  private(set) var advertisedRoots = false

  func record(advertisedRoots: Bool) {
    self.advertisedRoots = advertisedRoots
  }
}
