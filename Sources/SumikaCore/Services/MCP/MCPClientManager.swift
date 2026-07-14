import Foundation

public struct MCPServerStatus: Equatable, Sendable, Identifiable {
  public enum State: Equatable, Sendable {
    case disconnected
    case connecting
    case connected(toolCount: Int)
    case failed(message: String)
  }

  public var id: UUID { serverID }

  public var serverID: UUID
  public var serverName: String
  public var state: State

  public init(serverID: UUID, serverName: String, state: State) {
    self.serverID = serverID
    self.serverName = serverName
    self.state = state
  }
}

/// Connected dynamic tool executors grouped by their stable server identity.
public struct MCPAgentToolExecutorGroup: Sendable {
  public var serverID: UUID
  public var executors: [AnyToolExecutor]

  public init(serverID: UUID, executors: [AnyToolExecutor]) {
    self.serverID = serverID
    self.executors = executors
  }
}

extension MCPClientError {
  fileprivate var invalidatesConnection: Bool {
    switch self {
    case .notConnected, .serverExited:
      return true
    case .timedOut, .protocolError, .serverError:
      return false
    }
  }
}

/// Owns the stdio connections to all configured MCP servers and projects
/// their tools as dynamic executors for the agent registry.
///
/// The manager never reconnects on its own: connections start when a
/// configuration is applied (or a reconnect is requested) and a crashed
/// server is marked failed once the dead connection is observed.
public actor MCPClientManager: MCPToolCalling {
  private struct ActiveServer {
    var config: MCPServerConfig
    var slug: String
    var connectionToken: UUID
    var connection: MCPServerConnection?
    var tools: [MCPRemoteTool]
    var state: MCPServerStatus.State
  }

  private let makeConnection: @Sendable (MCPServerConfig) -> MCPServerConnection
  private var servers: [UUID: ActiveServer] = [:]
  private var serverOrder: [UUID] = []

  public init(
    makeConnection: @escaping @Sendable (MCPServerConfig) -> MCPServerConnection = {
      MCPServerConnection(config: $0)
    }
  ) {
    self.makeConnection = makeConnection
  }

  // MARK: - Configuration lifecycle

  /// Reconciles connections with the given configuration: removed, disabled,
  /// or launch-relevantly changed servers shut down; enabled servers without
  /// a live connection start.
  public func applyConfiguration(_ configs: [MCPServerConfig]) async {
    let configsByID = Dictionary(uniqueKeysWithValues: configs.map { ($0.id, $0) })

    for (id, server) in servers {
      let replacement = configsByID[id]
      let keepsConnection =
        replacement.map { !Self.requiresRestart(from: server.config, to: $0) && $0.isEnabled }
        ?? false
      if !keepsConnection {
        await server.connection?.shutdown()
        servers[id] = nil
      }
    }

    serverOrder = configs.map(\.id)
    var usedSlugs = Set(servers.values.map(\.slug))
    for config in configs {
      if var existing = servers[config.id] {
        existing.config = config
        servers[config.id] = existing
        continue
      }
      let slug = Self.uniqueSlug(for: config, used: &usedSlugs)
      servers[config.id] = ActiveServer(
        config: config,
        slug: slug,
        connectionToken: UUID(),
        connection: nil,
        tools: [],
        state: config.isEnabled ? .connecting : .disconnected
      )
      if config.isEnabled {
        await connect(serverID: config.id)
      }
    }
  }

  public func reconnect(serverID: UUID) async {
    guard let server = servers[serverID], server.config.isEnabled else {
      return
    }
    await server.connection?.shutdown()
    servers[serverID]?.connection = nil
    servers[serverID]?.tools = []
    servers[serverID]?.connectionToken = UUID()
    servers[serverID]?.state = .connecting
    await connect(serverID: serverID)
  }

  public func shutdownAll() async {
    for server in servers.values {
      await server.connection?.shutdown()
    }
    for id in servers.keys {
      servers[id]?.connection = nil
      servers[id]?.tools = []
      servers[id]?.state = .disconnected
    }
  }

  // MARK: - Projections

  public func statuses() -> [MCPServerStatus] {
    serverOrder.compactMap { id in
      servers[id].map {
        MCPServerStatus(serverID: id, serverName: $0.config.name, state: $0.state)
      }
    }
  }

  /// Dynamic executors for every tool on every connected server, in stable
  /// configuration order.
  public func agentToolExecutors() -> [AnyToolExecutor] {
    agentToolExecutorGroups().flatMap(\.executors)
  }

  /// Dynamic executors grouped by server, in stable configuration order.
  public func agentToolExecutorGroups() -> [MCPAgentToolExecutorGroup] {
    serverOrder.compactMap { id -> MCPAgentToolExecutorGroup? in
      guard let server = servers[id], case .connected = server.state else {
        return nil
      }
      let executors = server.tools.map { tool in
        AnyToolExecutor(
          dynamic: MCPToolExecutor(
            serverID: id,
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

  // MARK: - MCPToolCalling

  public func callTool(
    serverID: UUID,
    name: String,
    arguments: ToolCallArguments
  ) async throws -> MCPToolResult {
    guard let connection = servers[serverID]?.connection else {
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
    guard let server = servers[serverID] else {
      return
    }
    let connectionToken = server.connectionToken
    servers[serverID]?.state = .connecting
    let connection = makeConnection(server.config)
    do {
      let tools = try await connection.start()
      guard let current = servers[serverID],
        current.connectionToken == connectionToken,
        current.config.isEnabled
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

  private static func requiresRestart(
    from old: MCPServerConfig,
    to new: MCPServerConfig
  ) -> Bool {
    old.command != new.command
      || old.arguments != new.arguments
      || old.environment != new.environment
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
