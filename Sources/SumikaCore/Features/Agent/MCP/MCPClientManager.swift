import Foundation

package struct MCPServerStatus: Equatable, Sendable, Identifiable {
  package enum State: Equatable, Sendable {
    case disconnected
    case connecting
    case connected(toolCount: Int)
    case failed(message: String)
  }

  package var id: UUID { serverID }

  package var serverID: UUID
  package var state: State

  package init(serverID: UUID, state: State) {
    self.serverID = serverID
    self.state = state
  }
}

/// Connected dynamic tool executors grouped by their stable server identity.
struct MCPAgentToolExecutorGroup: Sendable {
  let serverID: UUID
  let executors: [AnyToolExecutor]
}

extension MCPClientError {
  fileprivate var invalidatesConnection: Bool {
    switch self {
    case .notConnected, .serverExited:
      return true
    case .staleConnection, .timedOut, .protocolError, .serverError:
      return false
    }
  }
}

/// Owns the MCP connections selected by the active Agent session and
/// projects their tools as dynamic executors for that session's registry.
///
/// Loading configuration alone never starts connections. The manager reconciles
/// explicit session/workspace scope and never reconnects a crashed server on
/// its own.
actor MCPClientManager: MCPToolCalling {
  private struct ActiveServer {
    var config: MCPServerConfig
    var slug: String
    var connectionToken: UUID
    var connection: MCPServerConnection?
    var tools: [MCPRemoteTool]
    var state: MCPServerStatus.State
    var isDesired: Bool
  }

  private struct ActiveScope: Equatable {
    var sessionID: ChatSession.ID
    var workspaceRootURL: URL

    static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.sessionID == rhs.sessionID && lhs.workspaceRootURL == rhs.workspaceRootURL
    }
  }

  private let makeConnection: @Sendable (MCPServerConfig, URL) -> MCPServerConnection
  private var servers: [UUID: ActiveServer] = [:]
  private var serverOrder: [UUID] = []
  private var activeScope: ActiveScope?
  private var selectedServerIDs: Set<UUID> = []

  init() {
    self.makeConnection = {
      MCPServerConnection(config: $0, workspaceRootURL: $1)
    }
  }

  init(
    makeConnection: @escaping @Sendable (MCPServerConfig, URL) -> MCPServerConnection
  ) {
    self.makeConnection = makeConnection
  }

  // MARK: - Configuration lifecycle

  /// Stores configuration without activating any server process.
  func applyConfiguration(_ configs: [MCPServerConfig]) async {
    await reconcile(
      configs: configs,
      activeSessionID: nil,
      selectedServerIDs: [],
      workspaceRootURL: nil
    )
  }

  /// Reconciles configured servers with the one active Agent session.
  func reconcile(
    configs: [MCPServerConfig],
    activeSessionID: ChatSession.ID?,
    selectedServerIDs: [UUID],
    workspaceRootURL: URL?
  ) async {
    let nextScope: ActiveScope? =
      if let activeSessionID, let workspaceRootURL {
        ActiveScope(
          sessionID: activeSessionID,
          workspaceRootURL: workspaceRootURL.standardizedFileURL.resolvingSymlinksInPath()
        )
      } else {
        nil
      }
    let scopeChanged = activeScope != nextScope
    activeScope = nextScope
    self.selectedServerIDs = Set(selectedServerIDs)

    if scopeChanged {
      for id in serverOrder {
        await deactivate(serverID: id)
      }
    }

    let configsByID = Dictionary(uniqueKeysWithValues: configs.map { ($0.id, $0) })

    for (id, server) in servers {
      let replacement = configsByID[id]
      if replacement == nil {
        await server.connection?.shutdown()
        servers[id] = nil
      }
    }

    serverOrder = configs.map(\.id)
    var usedSlugs: Set<String> = []
    for config in configs {
      let slug = Self.uniqueSlug(for: config, used: &usedSlugs)
      if var existing = servers[config.id] {
        let requiresRestart =
          Self.requiresRestart(from: existing.config, to: config)
          || existing.slug != slug
        existing.config = config
        existing.slug = slug
        servers[config.id] = existing
        if requiresRestart {
          await deactivate(serverID: config.id)
        }
      } else {
        servers[config.id] = ActiveServer(
          config: config,
          slug: slug,
          connectionToken: UUID(),
          connection: nil,
          tools: [],
          state: .disconnected,
          isDesired: false
        )
      }

      let shouldConnect =
        nextScope != nil
        && config.isEnabled
        && self.selectedServerIDs.contains(config.id)
      if shouldConnect, servers[config.id]?.isDesired == false {
        servers[config.id]?.isDesired = true
        servers[config.id]?.connectionToken = UUID()
        servers[config.id]?.state = .connecting
        await connect(serverID: config.id)
      } else if !shouldConnect, servers[config.id]?.isDesired == true {
        await deactivate(serverID: config.id)
      }
    }
  }

  func reconnect(serverID: UUID) async {
    guard let server = servers[serverID], server.config.isEnabled, server.isDesired else {
      return
    }
    await server.connection?.shutdown()
    servers[serverID]?.connection = nil
    servers[serverID]?.tools = []
    servers[serverID]?.connectionToken = UUID()
    servers[serverID]?.state = .connecting
    await connect(serverID: serverID)
  }

  func shutdownAll() async {
    for server in servers.values {
      await server.connection?.shutdown()
    }
    for id in servers.keys {
      servers[id]?.connection = nil
      servers[id]?.tools = []
      servers[id]?.state = .disconnected
      servers[id]?.isDesired = false
      servers[id]?.connectionToken = UUID()
    }
    activeScope = nil
    selectedServerIDs = []
  }

  /// Starts an isolated connection for Settings, lists tools, then always stops it.
  func testConnection(
    config: MCPServerConfig,
    workspaceRootURL: URL
  ) async throws -> Int {
    let connection = makeConnection(config, workspaceRootURL)
    do {
      let tools = try await connection.start()
      await connection.shutdown()
      return tools.count
    } catch {
      await connection.shutdown()
      throw error
    }
  }

  // MARK: - Projections

  func statuses() -> [MCPServerStatus] {
    serverOrder.compactMap { id in
      servers[id].map {
        MCPServerStatus(serverID: id, state: $0.state)
      }
    }
  }

  // Test-only flattened projection, exercised through @testable import.
  // Dynamic executors for every tool on every connected server, in stable
  // configuration order.
  // swiftlint:disable:next unused_declaration
  func agentToolExecutors() -> [AnyToolExecutor] {
    agentToolExecutorGroups().flatMap(\.executors)
  }

  /// Dynamic executors grouped by server, in stable configuration order.
  func agentToolExecutorGroups() -> [MCPAgentToolExecutorGroup] {
    serverOrder.compactMap { id -> MCPAgentToolExecutorGroup? in
      guard let server = servers[id], case .connected = server.state else {
        return nil
      }
      let executors = server.tools.map { tool in
        AnyToolExecutor(
          dynamic: MCPToolExecutor(
            serverID: id,
            connectionToken: server.connectionToken,
            serverName: server.config.name,
            serverSlug: server.slug,
            remoteTool: tool,
            client: self
          )
        )
      }
      return MCPAgentToolExecutorGroup(serverID: id, executors: executors)
    }
  }

  // Test-only; exercised through @testable import.
  // swiftlint:disable:next unused_declaration
  func connectionToken(for serverID: UUID) -> UUID? {
    servers[serverID]?.connectionToken
  }

  // MARK: - MCPToolCalling

  func callTool(
    serverID: UUID,
    connectionToken: UUID,
    name: String,
    arguments: ToolCallArguments
  ) async throws -> MCPToolResult {
    guard let current = servers[serverID], current.connectionToken == connectionToken else {
      throw MCPClientError.staleConnection
    }
    guard let connection = current.connection else {
      throw MCPClientError.notConnected
    }
    do {
      return try await connection.callTool(name: name, arguments: arguments)
    } catch let error as MCPClientError {
      if error.invalidatesConnection {
        let clearedConnection = markConnectionUnavailable(
          serverID: serverID,
          connection: connection,
          error: error
        )
        if clearedConnection {
          await connection.shutdown()
        }
      }
      throw error
    }
  }

  // MARK: - Connection helpers

  private func connect(serverID: UUID) async {
    guard let server = servers[serverID], server.isDesired, let activeScope else {
      return
    }
    let connectionToken = server.connectionToken
    servers[serverID]?.state = .connecting
    let connection = makeConnection(server.config, activeScope.workspaceRootURL)
    do {
      let tools = try await connection.start()
      guard let current = servers[serverID],
        current.connectionToken == connectionToken,
        current.config.isEnabled,
        current.isDesired
      else {
        await connection.shutdown()
        return
      }
      servers[serverID]?.connection = connection
      servers[serverID]?.tools = tools
      servers[serverID]?.state = .connected(toolCount: tools.count)
    } catch {
      await connection.shutdown()
      guard let current = servers[serverID],
        current.connectionToken == connectionToken
      else {
        return
      }
      servers[serverID]?.connection = nil
      servers[serverID]?.tools = []
      servers[serverID]?.state = .failed(message: error.localizedDescription)
    }
  }

  private func markConnectionUnavailable(
    serverID: UUID,
    connection: MCPServerConnection,
    error: MCPClientError
  ) -> Bool {
    guard let server = servers[serverID],
      let currentConnection = server.connection,
      currentConnection === connection
    else {
      return false
    }

    servers[serverID]?.connection = nil
    servers[serverID]?.tools = []
    servers[serverID]?.state = .failed(message: error.localizedDescription)
    return true
  }

  private func deactivate(serverID: UUID) async {
    guard let server = servers[serverID] else {
      return
    }
    await server.connection?.shutdown()
    servers[serverID]?.connection = nil
    servers[serverID]?.tools = []
    servers[serverID]?.state = .disconnected
    servers[serverID]?.isDesired = false
    servers[serverID]?.connectionToken = UUID()
  }

  private static func requiresRestart(
    from old: MCPServerConfig,
    to new: MCPServerConfig
  ) -> Bool {
    old.name != new.name || old.transport != new.transport
  }

  private static func uniqueSlug(
    for config: MCPServerConfig,
    used: inout Set<String>
  ) -> String {
    let base = config.slug
    var candidate = base
    var suffix = 2
    while used.contains(candidate) {
      candidate = "\(base)_\(suffix)"
      suffix += 1
    }
    used.insert(candidate)
    return candidate
  }
}
