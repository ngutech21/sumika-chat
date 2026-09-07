import Foundation
import MCP
import SumikaTestSupport
import Synchronization
import Testing

@testable import SumikaCore

@Suite(.serialized, TemporaryDirectoryTrait(named: "sumika-agent-feature-tests"))
@MainActor
struct AgentFeatureTests {
  @Test
  func queuedConnectionRefreshDoesNotRevertUserSelection() async throws {
    let session = ChatSession(interactionMode: .agent)
    let workspace = Workspace(
      name: "Probe", rootURL: try scopedTemporaryDirectory(), sessions: [session])
    let engine = ConversationEngine(
      runtime: ChatSessionFakeChatModelRuntime(), modelPath: "/tmp/model", chatSession: session)
    try engine.loadSession(from: workspace, sessionID: session.id)
    let agent = AgentFeature(conversationEngine: engine, clientManager: MCPClientManager())
    let server = MCPServerConfig(
      name: "Offline", command: "/usr/bin/false", isEnabled: false)
    await agent.loadServerConfiguration([server])
    let configuration = AgentConnectionConfiguration(
      servers: [server], activeSessionID: session.id, workspaceRootURL: workspace.rootURL)
    var selections: [[UUID]] = []
    engine.setSessionChangeHandler { _, snapshot in
      selections.append(snapshot.selectedMCPServerIDs)
      // Stop the faulty feedback path after its first rollback so a failing
      // assertion cannot leave an endlessly growing connection queue behind.
      guard snapshot.selectedMCPServerIDs == [server.id] else {
        engine.setSessionChangeHandler(nil)
        return
      }
      var selected = configuration
      selected.selectedServerIDs = snapshot.selectedMCPServerIDs
      agent.reconcile(selected)
    }

    agent.reconcile(configuration)
    agent.setSelectedMCPServerIDs([server.id])
    await agent.prepareForTermination()

    #expect(selections == [[server.id]])
    #expect(engine.composerSessionState.selectedMCPServerIDs == [server.id])
    engine.setSessionChangeHandler(nil)
  }

  @Test
  func initialConfigurationPreservesSessionSelection() async throws {
    let fixture = try AgentSelectionFixture()
    fixture.agent.setSelectedMCPServerIDs([fixture.server.id])

    await fixture.agent.loadServerConfiguration([fixture.server])
    await fixture.agent.prepareForTermination()

    #expect(fixture.engine.composerSessionState.selectedMCPServerIDs == [fixture.server.id])
  }

  @Test(arguments: SupersedingChange.allCases)
  func lateConnectionResultsPublishOnlyCurrentConfiguration(
    change: SupersedingChange
  ) async throws {
    let remote = try await ControlledMCPServer.start()
    let fixture = try AgentSelectionFixture(transports: [remote.transport])
    var published: [[MCPServerStatus]] = []
    fixture.agent.setStatusChangeHandler { published.append($0) }
    fixture.agent.setSelectedMCPServerIDs([fixture.server.id])
    let original = fixture.configuration(selected: true)
    fixture.agent.reconcile(original)
    await remote.gate.waitUntilRequested()

    var latest = original
    switch change {
    case .deselection:
      fixture.agent.setSelectedMCPServerIDs([])
      latest.selectedServerIDs = []
    case .session, .workspace:
      let session = ChatSession(interactionMode: .agent)
      let workspace = Workspace(
        name: "Next",
        rootURL: change == .workspace
          ? fixture.workspace.rootURL.appending(path: "next") : fixture.workspace.rootURL,
        sessions: [session])
      try fixture.engine.loadSession(from: workspace, sessionID: session.id)
      latest.activeSessionID = session.id
      latest.workspaceRootURL = workspace.rootURL
      latest.selectedServerIDs = []
    case .selectionRoundTrip:
      fixture.agent.setSelectedMCPServerIDs([])
      fixture.agent.reconcile(fixture.configuration(selected: false))
      fixture.agent.setSelectedMCPServerIDs([fixture.server.id])
    case .forcedRefresh:
      break
    }
    fixture.agent.reconcile(latest, force: change == .forcedRefresh)
    await remote.gate.release()
    await fixture.agent.prepareForTermination()
    await remote.server.stop()

    let remainsSelected = change == .selectionRoundTrip || change == .forcedRefresh
    #expect(fixture.engine.composerSessionState.selectedMCPServerIDs == latest.selectedServerIDs)
    #expect(
      published == [
        [
          MCPServerStatus(
            serverID: fixture.server.id,
            state: remainsSelected ? .connected(toolCount: 1) : .disconnected)
        ]
      ])
    #expect(fixture.mcpToolNames == (remainsSelected ? ["mcp__probe__echo"] : []))
    #expect(fixture.remainingTransportCount == 0)
  }

  @Test
  func queuedConfigurationLoadCannotReplaceNewerDesiredConfiguration() async throws {
    let remote = try await ControlledMCPServer.start()
    let fixture = try AgentSelectionFixture(transports: [remote.transport])
    var published: [[MCPServerStatus]] = []
    fixture.agent.setStatusChangeHandler { published.append($0) }
    fixture.agent.setSelectedMCPServerIDs([fixture.server.id])
    let configuration = fixture.configuration(selected: true)
    fixture.agent.reconcile(configuration)
    await remote.gate.waitUntilRequested()

    let started = AsyncStream<Void>.makeStream()
    let loading = Task {
      started.continuation.yield(())
      await fixture.agent.loadServerConfiguration([])
    }
    for await _ in started.stream { break }
    fixture.agent.reconcile(configuration)
    await remote.gate.release()
    await loading.value
    await fixture.agent.prepareForTermination()
    await remote.server.stop()

    #expect(
      published == [[MCPServerStatus(serverID: fixture.server.id, state: .connected(toolCount: 1))]]
    )
    #expect(fixture.engine.composerSessionState.selectedMCPServerIDs == [fixture.server.id])
    #expect(fixture.mcpToolNames == ["mcp__probe__echo"])
  }

  @Test(arguments: [false, true])
  func supersededActiveConnectionTestReportsCancellation(alreadyRunning: Bool) async throws {
    let first = try await ControlledMCPServer.start()
    let second = try await ControlledMCPServer.start()
    let fixture = try AgentSelectionFixture(transports: [first.transport, second.transport])
    var published: [[MCPServerStatus]] = []
    let connected = AsyncStream<Void>.makeStream()
    fixture.agent.setStatusChangeHandler {
      published.append($0)
      connected.continuation.yield(())
    }
    fixture.agent.setSelectedMCPServerIDs([fixture.server.id])
    fixture.agent.reconcile(fixture.configuration(selected: true))
    await first.gate.waitUntilRequested()
    if alreadyRunning {
      await first.gate.release()
      for await _ in connected.stream { break }
      published.removeAll()
    }

    var result: Result<AgentServerTestResult, Error>?
    fixture.agent.testServer(
      server: fixture.server, workspaceRootURL: fixture.workspace.rootURL,
      reconnectActiveServer: true
    ) { result = $0 }
    if alreadyRunning { await second.gate.waitUntilRequested() }
    fixture.agent.setSelectedMCPServerIDs([])
    fixture.agent.reconcile(fixture.configuration(selected: false))
    await first.gate.release()
    await second.gate.release()
    await fixture.agent.prepareForTermination()
    await first.server.stop()
    await second.server.stop()

    guard case .failure(let error) = result else {
      Issue.record("A superseded active connection test must report cancellation")
      return
    }
    #expect(error is CancellationError)
    #expect(published == [[MCPServerStatus(serverID: fixture.server.id, state: .disconnected)]])
    #expect(fixture.engine.composerSessionState.selectedMCPServerIDs.isEmpty)
    #expect(fixture.mcpToolNames.isEmpty)
    #expect(fixture.remainingTransportCount == (alreadyRunning ? 0 : 1))
  }

  @Test
  func isolatedConnectionTestDoesNotPublishOrChangeSelection() async throws {
    let remote = try await ControlledMCPServer.start()
    let fixture = try AgentSelectionFixture(transports: [remote.transport])
    var published: [[MCPServerStatus]] = []
    fixture.agent.setStatusChangeHandler { published.append($0) }
    var result: Result<AgentServerTestResult, Error>?
    fixture.agent.testServer(
      server: fixture.server, workspaceRootURL: fixture.workspace.rootURL,
      reconnectActiveServer: false
    ) { result = $0 }
    await remote.gate.waitUntilRequested()
    fixture.agent.setSelectedMCPServerIDs([fixture.server.id])
    await remote.gate.release()
    await fixture.agent.prepareForTermination()
    await remote.server.stop()

    guard case .success(.isolatedConnection(let count)) = result else {
      Issue.record("An isolated connection test must still return its tool count")
      return
    }
    #expect(count == 1)
    #expect(published.isEmpty)
    #expect(fixture.engine.composerSessionState.selectedMCPServerIDs == [fixture.server.id])
    #expect(fixture.mcpToolNames.isEmpty)
  }

  enum SupersedingChange: CaseIterable, Sendable {
    case deselection, session, workspace, selectionRoundTrip, forcedRefresh
  }
}

@MainActor
private final class AgentSelectionFixture {
  let workspace: Workspace
  let engine: ConversationEngine
  let agent: AgentFeature
  let server: MCPServerConfig
  private let transports: MCPTransportPool

  init(transports: [InMemoryTransport] = []) throws {
    let session = ChatSession(interactionMode: .agent)
    workspace = Workspace(
      name: "Probe", rootURL: try scopedTemporaryDirectory(), sessions: [session])
    engine = ConversationEngine(
      runtime: ChatSessionFakeChatModelRuntime(), modelPath: "/tmp/model", chatSession: session)
    try engine.loadSession(from: workspace, sessionID: session.id)
    let endpoint = try #require(URL(string: "https://mcp.example.invalid"))
    server = MCPServerConfig(
      name: "Probe",
      transport: .streamableHTTP(endpoint: endpoint),
      isEnabled: !transports.isEmpty)
    let pool = MCPTransportPool(transports: transports)
    self.transports = pool
    let manager = MCPClientManager { config, root in
      let transport = pool.transports.withLock { $0.removeFirst() }
      return MCPServerConnection(
        config: config, workspaceRootURL: root, makeHTTPTransport: { _ in transport })
    }
    agent = AgentFeature(conversationEngine: engine, clientManager: manager)
  }

  func configuration(selected: Bool) -> AgentConnectionConfiguration {
    AgentConnectionConfiguration(
      servers: [server], activeSessionID: engine.activeSessionID,
      selectedServerIDs: selected ? [server.id] : [], workspaceRootURL: workspace.rootURL)
  }

  var mcpToolNames: [String] {
    engine.effectiveToolOrchestrator(for: .agent)?.toolRegistry.tools
      .filter { $0.capabilities.contains(.externalService) }.map(\.name.rawValue) ?? []
  }

  var remainingTransportCount: Int { transports.transports.withLock { $0.count } }
}

private final class MCPTransportPool: Sendable {
  let transports: Mutex<[InMemoryTransport]>

  init(transports: [InMemoryTransport]) {
    self.transports = Mutex(transports)
  }
}

private struct ControlledMCPServer {
  let server: Server
  let transport: InMemoryTransport
  let gate: MCPResponseGate

  static func start() async throws -> Self {
    let pair = await InMemoryTransport.createConnectedPair()
    let gate = MCPResponseGate()
    let server = Server(name: "Probe", version: "1.0", capabilities: .init(tools: .init()))
    await server.withMethodHandler(ListTools.self) { _ in
      await gate.request()
      return ListTools.Result(tools: [
        Tool(name: "echo", description: "Echo", inputSchema: ["type": "object"])
      ])
    }
    try await server.start(transport: pair.server)
    return Self(server: server, transport: pair.client, gate: gate)
  }
}

private actor MCPResponseGate {
  private var requested = false
  private var released = false
  private var requestWaiters: [CheckedContinuation<Void, Never>] = []
  private var responseWaiter: CheckedContinuation<Void, Never>?

  func request() async {
    requested = true
    for waiter in requestWaiters { waiter.resume() }
    requestWaiters.removeAll()
    if !released {
      await withCheckedContinuation { responseWaiter = $0 }
    }
  }

  func waitUntilRequested() async {
    if !requested {
      await withCheckedContinuation { requestWaiters.append($0) }
    }
  }

  func release() {
    released = true
    responseWaiter?.resume()
    responseWaiter = nil
  }
}
