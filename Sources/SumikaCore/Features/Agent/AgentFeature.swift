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
    let configuration = AgentConnectionConfiguration(servers: servers)
    desiredConnectionConfiguration = configuration
    connectionConfigurationRevision += 1
    let revision = connectionConfigurationRevision
    let task = enqueueMutation { [weak self] in
      guard let self, revision == self.connectionConfigurationRevision else {
        return
      }
      await self.clientManager.applyConfiguration(servers)
      _ = await self.refreshAfterMCPChange(revision: revision)
    }
    await task.value
  }

  package func reconcile(
    _ configuration: AgentConnectionConfiguration,
    force: Bool = false
  ) {
    guard force || desiredConnectionConfiguration != configuration else {
      return
    }
    desiredConnectionConfiguration = configuration
    connectionConfigurationRevision += 1
    let revision = connectionConfigurationRevision
    enqueueMutation { [weak self] in
      guard let self, revision == self.connectionConfigurationRevision else {
        return
      }
      await self.clientManager.reconcile(
        configs: configuration.servers,
        activeSessionID: configuration.activeSessionID,
        selectedServerIDs: configuration.selectedServerIDs,
        workspaceRootURL: configuration.workspaceRootURL
      )
      _ = await self.refreshAfterMCPChange(revision: revision)
    }
  }

  package func testServer(
    server: MCPServerConfig,
    workspaceRootURL: URL,
    reconnectActiveServer: Bool,
    completion: @escaping @MainActor @Sendable (Result<AgentServerTestResult, Error>) -> Void
  ) {
    let revision = connectionConfigurationRevision
    enqueueMutation { [weak self] in
      guard let self else {
        return
      }
      if reconnectActiveServer {
        guard revision == self.connectionConfigurationRevision else {
          completion(.failure(CancellationError()))
          return
        }
        await self.clientManager.reconnect(serverID: server.id)
        guard let statuses = await self.refreshAfterMCPChange(revision: revision) else {
          completion(.failure(CancellationError()))
          return
        }
        let status = statuses.first { $0.serverID == server.id }
        completion(.success(.activeConnection(status?.state)))
        return
      }
      do {
        let toolCount = try await self.clientManager.testConnection(
          config: server,
          workspaceRootURL: workspaceRootURL
        )
        completion(.success(.isolatedConnection(toolCount: toolCount)))
      } catch {
        completion(.failure(error))
      }
    }
  }

  package func prepareForTermination() async {
    await mutationTask?.value
    await clientManager.shutdownAll()
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

  private func refreshAfterMCPChange(revision: Int) async -> [MCPServerStatus]? {
    let statuses = await clientManager.statuses()
    let groups = await clientManager.agentToolExecutorGroups()
    // Both actor reads can suspend. Publish only the latest configuration,
    // and never turn a connection result back into a session-selection edit.
    guard revision == connectionConfigurationRevision else {
      return nil
    }
    executorGroups = groups
    conversationEngine.configureAgentTools(
      todoWriteEnabled: todoWriteEnabled,
      mcpExecutorGroups: groups
    )
    statusChangeHandler?(statuses)
    return statuses
  }
}
