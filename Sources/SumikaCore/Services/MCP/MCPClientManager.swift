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

/// Owns the stdio connections to all configured MCP servers and projects
/// their tools as dynamic executors for the agent registry.
///
/// The manager never reconnects on its own: connections start when a
/// configuration is applied (or a reconnect is requested) and a crashed
/// server surfaces as failed tool calls plus a failed status after the next
/// explicit reconcile.
public actor MCPClientManager: MCPToolCalling {
  private struct ActiveServer {
    var config: MCPServerConfig
    var slug: String
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
    serverOrder.flatMap { id -> [AnyToolExecutor] in
      guard let server = servers[id], case .connected = server.state else {
        return []
      }
      return server.tools.map { tool in
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
    return try await connection.callTool(name: name, arguments: arguments)
  }

  // MARK: - Connection helpers

  private func connect(serverID: UUID) async {
    guard let server = servers[serverID] else {
      return
    }
    servers[serverID]?.state = .connecting
    let connection = makeConnection(server.config)
    do {
      let tools = try await connection.start()
      guard servers[serverID] != nil else {
        await connection.shutdown()
        return
      }
      servers[serverID]?.connection = connection
      servers[serverID]?.tools = tools
      servers[serverID]?.state = .connected(toolCount: tools.count)
    } catch {
      await connection.shutdown()
      guard servers[serverID] != nil else {
        return
      }
      servers[serverID]?.connection = nil
      servers[serverID]?.tools = []
      servers[serverID]?.state = .failed(message: error.localizedDescription)
    }
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
