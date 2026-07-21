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
    let task = enqueueMutation { [weak self] in
      guard let self else {
        return
      }
      await self.clientManager.applyConfiguration(servers)
      await self.refreshAfterMCPChange(selectedServerIDs: [])
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
    enqueueMutation { [weak self] in
      guard let self else {
        return
      }
      await self.clientManager.reconcile(
        configs: configuration.servers,
        activeSessionID: configuration.activeSessionID,
        selectedServerIDs: configuration.selectedServerIDs,
        workspaceRootURL: configuration.workspaceRootURL
      )
      await self.refreshAfterMCPChange(selectedServerIDs: configuration.selectedServerIDs)
    }
  }

  package func testServer(
    server: MCPServerConfig,
    workspaceRootURL: URL,
    reconnectActiveServer: Bool,
    completion: @escaping @MainActor @Sendable (Result<AgentServerTestResult, Error>) -> Void
  ) {
    enqueueMutation { [weak self] in
      guard let self else {
        return
      }
      if reconnectActiveServer {
        await self.clientManager.reconnect(serverID: server.id)
        await self.refreshAfterMCPChange(
          selectedServerIDs: self.desiredConnectionConfiguration?.selectedServerIDs
            ?? self.conversationEngine.composerSessionState.selectedMCPServerIDs
        )
        let status = await self.clientManager.statuses().first { $0.serverID == server.id }
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

  private func refreshAfterMCPChange(selectedServerIDs: [UUID]) async {
    let statuses = await clientManager.statuses()
    executorGroups = await clientManager.agentToolExecutorGroups()
    conversationEngine.reconcileAgentTools(
      todoWriteEnabled: todoWriteEnabled,
      mcpExecutorGroups: executorGroups,
      selectedMCPServerIDs: selectedServerIDs
    )
    statusChangeHandler?(statuses)
  }
}
