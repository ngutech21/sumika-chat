import Foundation

package struct AgentConnectionConfiguration: Equatable, Sendable {
  package var servers: [MCPServerConfig]
  package var activeSessionID: ChatSession.ID?
  package var selectedServerIDs: [UUID]
  package var workspaceRootURL: URL?

  package init(
    servers: [MCPServerConfig],
    activeSessionID: ChatSession.ID? = nil,
    selectedServerIDs: [UUID] = [],
    workspaceRootURL: URL? = nil
  ) {
    self.servers = servers
    self.activeSessionID = activeSessionID
    self.selectedServerIDs = selectedServerIDs
    self.workspaceRootURL = workspaceRootURL
  }
}

package enum AgentServerTestResult: Equatable, Sendable {
  case activeConnection(MCPServerStatus.State?)
  case isolatedConnection(toolCount: Int)
}

/// Package-visible Agent configuration and MCP lifecycle. Dynamic executor
/// contributions never cross this interface.
@MainActor
package final class AgentFeature {
  private let conversationEngine: ConversationEngine
  private let clientManager: MCPClientManager
  private var todoWriteEnabled = false
  private var executorGroups: [MCPAgentToolExecutorGroup] = []
  private var desiredConnectionConfiguration: AgentConnectionConfiguration?
  private var connectionConfigurationRevision = 0
  private var mutationTask: Task<Void, Never>?
  private var isTerminating = false
  private var isObserving = false
  private var lastSequence = 0
  private var lastStatuses: [MCPServerStatus]?
  private struct ServerTest {
    let id: UUID
    let config: MCPServerConfig
    let workspaceRootURL: URL
    let activeSessionID: ChatSession.ID?
    let reconnectsActiveServer: Bool
    let task: Task<Void, Never>
  }
  private var serverTests: [UUID: ServerTest] = [:]
  private var statusChangeHandler: (@MainActor @Sendable ([MCPServerStatus]) -> Void)?

  init(
    conversationEngine: ConversationEngine,
    clientManager: MCPClientManager
  ) {
    self.conversationEngine = conversationEngine
    self.clientManager = clientManager
    conversationEngine.configureAgentTools(todoWriteEnabled: false)
  }

  package func updateConfiguration(todoWriteEnabled: Bool) {
    self.todoWriteEnabled = todoWriteEnabled
    conversationEngine.configureAgentTools(
      todoWriteEnabled: todoWriteEnabled,
      mcpExecutorGroups: executorGroups
    )
  }

  package func setStatusChangeHandler(
    _ handler: (@MainActor @Sendable ([MCPServerStatus]) -> Void)?
  ) {
    statusChangeHandler = handler
  }

  package func setSelectedMCPServerIDs(_ serverIDs: [UUID]) {
    conversationEngine.setSelectedMCPServerIDs(serverIDs)
  }

  package func reconcileSelectedMCPServerIDs(_ serverIDs: [UUID]) {
    conversationEngine.reconcileSelectedMCPServerIDs(serverIDs)
  }

  package func loadServerConfiguration(_ servers: [MCPServerConfig]) async {
    guard !isTerminating else { return }
    let configuration = AgentConnectionConfiguration(servers: servers)
    cancelInvalidatedTests(configuration)
    desiredConnectionConfiguration = configuration
    connectionConfigurationRevision += 1
    let revision = connectionConfigurationRevision
    let task = enqueueMutation { [weak self] in
      guard let self, !self.isTerminating, revision == self.connectionConfigurationRevision else {
        return
      }
      await self.observeConnections()
      await self.clientManager.applyConfiguration(servers, revision: revision)
    }
    await task.value
  }

  package func reconcile(
    _ configuration: AgentConnectionConfiguration,
    force: Bool = false
  ) {
    guard !isTerminating, force || desiredConnectionConfiguration != configuration else {
      return
    }
    cancelInvalidatedTests(configuration)
    desiredConnectionConfiguration = configuration
    connectionConfigurationRevision += 1
    let revision = connectionConfigurationRevision
    enqueueMutation { [weak self] in
      guard let self, !self.isTerminating, revision == self.connectionConfigurationRevision else {
        return
      }
      await self.observeConnections()
      await self.clientManager.reconcile(
        configs: configuration.servers,
        activeSessionID: configuration.activeSessionID,
        selectedServerIDs: configuration.selectedServerIDs,
        workspaceRootURL: configuration.workspaceRootURL,
        revision: revision
      )
    }
  }

  package func testServer(
    server: MCPServerConfig,
    workspaceRootURL: URL,
    reconnectActiveServer: Bool,
    completion: @escaping @MainActor @Sendable (Result<AgentServerTestResult, Error>) -> Void
  ) {
    guard !isTerminating, serverTests[server.id] == nil else {
      completion(.failure(CancellationError()))
      return
    }
    let id = UUID()
    let precedingMutation = mutationTask
    let task = Task { [weak self] in
      guard let self else { return }
      let result: Result<AgentServerTestResult, Error>
      do {
        try Task.checkCancellation()
        if reconnectActiveServer {
          await precedingMutation?.value
          try Task.checkCancellation()
          await self.clientManager.reconnect(serverID: server.id)
          let statuses = await self.clientManager.statuses()
          try Task.checkCancellation()
          result = .success(.activeConnection(statuses.first { $0.id == server.id }?.state))
        } else {
          let count = try await self.clientManager.testConnection(
            config: server, workspaceRootURL: workspaceRootURL)
          try Task.checkCancellation()
          result = .success(.isolatedConnection(toolCount: count))
        }
      } catch {
        result = .failure(Task.isCancelled ? CancellationError() : error)
      }
      if self.serverTests[server.id]?.id == id {
        self.serverTests[server.id] = nil
      }
      completion(result)
    }
    serverTests[server.id] = ServerTest(
      id: id, config: server, workspaceRootURL: workspaceRootURL.standardizedFileURL,
      activeSessionID: desiredConnectionConfiguration?.activeSessionID,
      reconnectsActiveServer: reconnectActiveServer, task: task)
  }

  package func cancelServerTest(_ serverID: UUID) {
    serverTests[serverID]?.task.cancel()
  }

  package func cancelServerTests(outsideWorkspaceRootURL workspaceRootURL: URL?) {
    let selectedRoot = workspaceRootURL?.standardizedFileURL
    for test in serverTests.values where test.workspaceRootURL != selectedRoot {
      test.task.cancel()
    }
  }

  private func cancelInvalidatedTests(_ configuration: AgentConnectionConfiguration) {
    for (id, test) in serverTests {
      let config = configuration.servers.first { $0.id == id }
      let contextChanged =
        test.reconnectsActiveServer
        && configuration.workspaceRootURL?.standardizedFileURL
          != desiredConnectionConfiguration?.workspaceRootURL?.standardizedFileURL
      let selectionChanged =
        test.reconnectsActiveServer
        && (configuration.activeSessionID != test.activeSessionID
          || !configuration.selectedServerIDs.contains(id))
      if config != test.config || config?.isEnabled != true || contextChanged || selectionChanged {
        test.task.cancel()
      }
    }
  }

  package func prepareForTermination() async {
    isTerminating = true
    let tests = serverTests.values.map(\.task)
    for task in tests { task.cancel() }
    await mutationTask?.value
    await clientManager.shutdownAll()
    for task in tests { await task.value }
    executorGroups = []
    conversationEngine.configureAgentTools(todoWriteEnabled: todoWriteEnabled)
  }

  @discardableResult
  private func enqueueMutation(
    _ operation: @escaping @MainActor @Sendable () async -> Void
  ) -> Task<Void, Never> {
    let previousTask = mutationTask
    let task = Task {
      await previousTask?.value
      await operation()
    }
    mutationTask = task
    return task
  }

  private func observeConnections() async {
    guard !isObserving else { return }
    isObserving = true
    await clientManager.setChangeHandler { [weak self] snapshot in
      await self?.receive(snapshot)
    }
  }

  private func receive(_ snapshot: MCPClientManager.Snapshot) {
    guard !isTerminating, snapshot.revision == connectionConfigurationRevision,
      snapshot.sequence > lastSequence
    else { return }
    lastSequence = snapshot.sequence
    executorGroups = snapshot.groups
    conversationEngine.configureAgentTools(
      todoWriteEnabled: todoWriteEnabled, mcpExecutorGroups: executorGroups)
    if lastStatuses != snapshot.statuses {
      lastStatuses = snapshot.statuses
      statusChangeHandler?(snapshot.statuses)
    }
  }
}
