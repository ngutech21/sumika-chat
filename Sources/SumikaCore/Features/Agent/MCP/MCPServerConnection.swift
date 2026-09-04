import Foundation
import MCP

enum MCPClientError: LocalizedError, Equatable {
  case notConnected
  case staleConnection
  case serverExited(detail: String?)
  case timedOut(method: String)
  case resourceLimit(String)
  case protocolError(String)
  case serverError(code: Int, message: String)

  var errorDescription: String? {
    switch self {
    case .notConnected:
      return "The MCP server is not connected."
    case .staleConnection:
      return "The MCP tool belongs to an obsolete server connection."
    case .serverExited(let detail):
      guard let detail, !detail.isEmpty else {
        return "The MCP server process exited."
      }
      return "The MCP server process exited: \(detail)"
    case .timedOut(let method):
      return "The MCP server did not answer \(method) in time."
    case .resourceLimit(let message):
      return "The MCP server exceeded a process I/O limit: \(message)"
    case .protocolError(let message):
      return "The MCP server sent an invalid response: \(message)"
    case .serverError(let code, let message):
      return "The MCP server reported an error (\(code)): \(message)"
    }
  }
}

/// One SDK-backed stdio or Streamable HTTP connection to a configured MCP server.
///
/// Sumika owns bounded stdio framing, child processes, and transport selection.
/// The MCP SDK owns JSON-RPC, lifecycle negotiation, roots, and typed requests.
actor MCPServerConnection {
  typealias HTTPTransportFactory = @Sendable (URL) -> any Transport

  private enum Timeouts {
    // npx/uvx may download packages on first launch.
    static let initializeSeconds = 30
    static let listToolsSeconds = 30
  }

  private static let maxToolListPages = 16
  private static let maxResultTextCharacters = 64_000

  private let config: MCPServerConfig
  private let workspaceRootURL: URL
  private let baseEnvironment: [String: String]
  private let pathPrefixDirectories: [URL]
  private let makeHTTPTransport: HTTPTransportFactory
  private let callToolTimeout: Duration

  private var process: OwnedProcess?
  private var client: Client?
  private var processTask: Task<Void, Never>?
  private var exitError: MCPClientError?
  private var didStart = false
  private var isShuttingDown = false
  private var failureHandler: (@Sendable (MCPClientError) async -> Void)?

  init(
    config: MCPServerConfig,
    workspaceRootURL: URL,
    baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
    pathPrefixDirectories: [URL] = [
      URL(filePath: "/opt/homebrew/bin"),
      URL(filePath: "/usr/local/bin"),
      URL(filePath: "/opt/local/bin"),
    ],
    callToolTimeout: Duration = .seconds(120)
  ) {
    self.config = config
    self.workspaceRootURL = workspaceRootURL.standardizedFileURL.resolvingSymlinksInPath()
    self.baseEnvironment = baseEnvironment
    self.pathPrefixDirectories = pathPrefixDirectories
    self.callToolTimeout = callToolTimeout
    self.makeHTTPTransport = { endpoint in
      HTTPClientTransport(endpoint: endpoint, streaming: true)
    }
  }

  init(
    config: MCPServerConfig,
    workspaceRootURL: URL,
    baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
    pathPrefixDirectories: [URL] = [
      URL(filePath: "/opt/homebrew/bin"),
      URL(filePath: "/usr/local/bin"),
      URL(filePath: "/opt/local/bin"),
    ],
    makeHTTPTransport: @escaping HTTPTransportFactory
  ) {
    self.config = config
    self.workspaceRootURL = workspaceRootURL.standardizedFileURL.resolvingSymlinksInPath()
    self.baseEnvironment = baseEnvironment
    self.pathPrefixDirectories = pathPrefixDirectories
    self.callToolTimeout = .seconds(120)
    self.makeHTTPTransport = makeHTTPTransport
  }

  // MARK: - Lifecycle

  func setFailureHandler(_ handler: @escaping @Sendable (MCPClientError) async -> Void) {
    failureHandler = handler
  }

  /// Creates the configured transport, performs SDK-managed initialization,
  /// and returns the server's tools.
  func start() async throws -> [MCPRemoteTool] {
    guard !didStart, !isShuttingDown else {
      throw MCPClientError.protocolError("Connection was already started.")
    }
    didStart = true

    let transport: any Transport
    let exposesWorkspaceRoots: Bool
    switch config.transport {
    case .stdio(let command, let arguments, let environment):
      transport = try await launchProcess(
        command: command,
        arguments: arguments,
        environment: environment
      )
      exposesWorkspaceRoots = true
    case .streamableHTTP(let endpoint):
      try MCPServerTransportConfiguration.validateStreamableHTTPEndpoint(endpoint)
      transport = makeHTTPTransport(endpoint)
      exposesWorkspaceRoots = MCPServerTransportConfiguration.isLoopbackEndpoint(endpoint)
    }

    let client = Client(
      name: "Sumika",
      version: "1.0",
      capabilities: .init(
        roots: exposesWorkspaceRoots ? .init(listChanged: false) : nil
      )
    )
    if exposesWorkspaceRoots {
      await client.withRootsHandler { [workspaceRootURL] in
        [Root(uri: workspaceRootURL.absoluteString)]
      }
    }
    self.client = client

    do {
      guard !isShuttingDown else {
        throw CancellationError()
      }
      if let exitError {
        throw exitError
      }
      try await connect(client: client, transport: transport)
      return try await listTools(client: client)
    } catch {
      if error is CancellationError {
        await shutdown()
        throw error
      }
      let mapped = await mappedError(error)
      await shutdown()
      throw mapped
    }
  }

  func shutdown() async {
    isShuttingDown = true
    let process = process
    let client = client
    let processTask = processTask
    self.process = nil
    self.client = nil
    self.processTask = nil

    // Stop independently of SDK task/transport progress, then unblock requests.
    _ = await process?.stop(.stopped)
    await client?.disconnect()
    processTask?.cancel()
    await processTask?.value
  }

  // MARK: - Requests

  func callTool(name: String, arguments: ToolCallArguments) async throws -> MCPToolResult {
    if let exitError {
      throw exitError
    }
    guard let client else {
      throw MCPClientError.notConnected
    }

    do {
      let context: RequestContext<CallTool.Result> = try await client.callTool(
        name: name,
        arguments: Self.mcpArguments(from: arguments)
      )
      let result = try await awaitRequest(
        context,
        client: client,
        method: "tools/call",
        timeout: callToolTimeout
      )
      return Self.toolResult(from: result, serverName: config.name, remoteToolName: name)
    } catch {
      if error is CancellationError {
        throw error
      }
      throw await mappedError(error)
    }
  }

  private func listTools(client: Client) async throws -> [MCPRemoteTool] {
    var tools: [MCPRemoteTool] = []
    var cursor: String?
    for _ in 0..<Self.maxToolListPages {
      let request: Request<ListTools> =
        if let cursor {
          ListTools.request(.init(cursor: cursor))
        } else {
          ListTools.request(.init())
        }
      let context: RequestContext<ListTools.Result> = try await client.send(request)
      let result = try await awaitRequest(
        context,
        client: client,
        method: "tools/list",
        timeout: .seconds(Timeouts.listToolsSeconds)
      )
      tools.append(contentsOf: result.tools.map(Self.remoteTool(from:)))
      guard let nextCursor = result.nextCursor, !nextCursor.isEmpty else {
        return tools
      }
      cursor = nextCursor
    }
    return tools
  }

  private func connect(client: Client, transport: any Transport) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        _ = try await client.connect(transport: transport)
      }
      group.addTask {
        try await Task.sleep(for: .seconds(Timeouts.initializeSeconds))
        throw MCPClientError.timedOut(method: "initialize")
      }

      do {
        _ = try await group.next()
        group.cancelAll()
      } catch {
        group.cancelAll()
        if case .stdio = config.transport, error is CancellationError || error is MCPClientError {
          await stopStdioRequest(error: error)
        } else {
          await client.disconnect()
        }
        throw error
      }
    }
  }

  private func awaitRequest<Output>(
    _ context: RequestContext<Output>,
    client: Client,
    method: String,
    timeout: Duration
  ) async throws -> Output where Output: Decodable & Sendable {
    try await withThrowingTaskGroup(of: Output.self) { group in
      group.addTask {
        try await context.value
      }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw MCPClientError.timedOut(method: method)
      }

      do {
        guard let result = try await group.next() else {
          throw MCPClientError.notConnected
        }
        group.cancelAll()
        return result
      } catch {
        group.cancelAll()
        if error is CancellationError || error is MCPClientError {
          if case .stdio = config.transport {
            await stopStdioRequest(error: error)
          } else {
            try? await client.cancelRequest(
              context.requestID,
              reason: "Sumika stopped waiting for \(method)."
            )
          }
        }
        throw error
      }
    }
  }

  private func stopStdioRequest(error: any Error) async {
    // Cancellation notifications use the same possibly blocked stdin pipe.
    // Stop the process before awaiting SDK request tasks or their send tasks.
    let failure = exitError ?? (error as? MCPClientError) ?? .notConnected
    exitError = failure
    await shutdown()
    await failureHandler?(failure)
  }

  // MARK: - Process

  private func launchProcess(
    command: String,
    arguments: [String],
    environment: [String: String]
  ) async throws -> MCPStdioTransport {
    let process = try await OwnedProcess.start(
      executableURL: URL(filePath: "/usr/bin/env"),
      arguments: [command] + arguments,
      environment: resolvedEnvironment(overrides: environment),
      workingDirectoryURL: workspaceRootURL,
      stdout: .frames(maxBytes: 8 * 1024 * 1024, queuedFrames: 2),
      stderrLimit: 8 * 1024,
      stderrRetention: .tail,
      maxWriteBytes: 8 * 1024 * 1024 + 1,
      maxPendingWrites: 2
    )
    guard !isShuttingDown else {
      _ = await process.stop(.stopped)
      throw CancellationError()
    }

    self.process = process
    processTask = Task { [weak self, process] in
      let result = await process.wait()
      // Successful final responses must drain before normal EOF disconnects
      // the SDK. Resource failures invalidate requests regardless of that queue.
      if case .exited = result.termination {
        return
      }
      await self?.handleProcessExit(result)
    }
    return MCPStdioTransport(process: process) { [weak self, process] in
      Task {
        // A server can close stdout while staying alive. EOF still closes the
        // protocol connection, so do not wait indefinitely for a separate exit.
        let result = await process.stop(.stopped)
        await self?.handleProcessExit(result)
      }
    }
  }

  private func resolvedEnvironment(overrides: [String: String]) -> [String: String] {
    var resolved = baseEnvironment
    let existingPath = resolved["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    let prefix =
      pathPrefixDirectories
      .map { $0.path(percentEncoded: false) }
      .joined(separator: ":")
    resolved["PATH"] = prefix.isEmpty ? existingPath : prefix + ":" + existingPath
    for (key, value) in overrides {
      resolved[key] = value
    }
    return resolved
  }

  private func handleProcessExit(_ result: OwnedProcess.Result) async {
    guard !isShuttingDown, exitError == nil else {
      return
    }
    let error: MCPClientError
    switch result.termination {
    case .failed(.resourceLimit(let detail)):
      error = .resourceLimit(detail)
    case .failed(let failure):
      error = .serverExited(detail: failure.localizedDescription)
    case .exited, .timedOut, .cancelled, .stopped:
      let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
      error = .serverExited(detail: detail.isEmpty ? nil : detail)
    }
    exitError = error
    await client?.disconnect()
    await failureHandler?(error)
  }

  // MARK: - Boundary mapping

  private static func remoteTool(from tool: Tool) -> MCPRemoteTool {
    MCPRemoteTool(
      name: tool.name,
      description: tool.description ?? "",
      inputSchema: toolArgumentValue(from: tool.inputSchema)
    )
  }

  static func toolResult(
    from result: CallTool.Result,
    serverName: String,
    remoteToolName: String
  ) -> MCPToolResult {
    var blocks: [MCPToolContentBlock] = []
    var remainingCharacters = maxResultTextCharacters
    var truncated = false

    for entry in result.content {
      switch entry {
      case .text(let text, _, _):
        guard remainingCharacters > 0 else {
          truncated = true
          continue
        }
        if text.count > remainingCharacters {
          blocks.append(.text(String(text.prefix(remainingCharacters))))
          remainingCharacters = 0
          truncated = true
        } else {
          blocks.append(.text(text))
          remainingCharacters -= text.count
        }
      case .image:
        blocks.append(.unsupported(type: "image"))
      case .audio:
        blocks.append(.unsupported(type: "audio"))
      case .resource:
        blocks.append(.unsupported(type: "resource"))
      case .resourceLink:
        blocks.append(.unsupported(type: "resource_link"))
      }
    }

    if blocks.isEmpty, let structured = result.structuredContent {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      if let data = try? encoder.encode(structured),
        let text = String(data: data, encoding: .utf8)
      {
        let limited = String(text.prefix(maxResultTextCharacters))
        blocks.append(.text(limited))
        truncated = limited.count < text.count
      }
    }

    return MCPToolResult(
      serverName: serverName,
      remoteToolName: remoteToolName,
      content: blocks,
      isError: result.isError ?? false,
      truncated: truncated
    )
  }

  private static func mcpArguments(from arguments: ToolCallArguments) -> [String: MCP.Value] {
    arguments.mapValues(mcpValue(from:))
  }

  private static func mcpValue(from value: ToolArgumentValue) -> MCP.Value {
    switch value {
    case .string(let value):
      .string(value)
    case .number(let value):
      .double(value)
    case .bool(let value):
      .bool(value)
    case .array(let values):
      .array(values.map(mcpValue(from:)))
    case .object(let values):
      .object(values.mapValues(mcpValue(from:)))
    case .null:
      .null
    }
  }

  private static func toolArgumentValue(from value: MCP.Value) -> ToolArgumentValue? {
    guard let data = try? JSONEncoder().encode(value) else {
      return nil
    }
    return try? JSONDecoder().decode(ToolArgumentValue.self, from: data)
  }

  private func mappedError(_ error: any Error) async -> MCPClientError {
    if let exitError {
      return exitError
    }
    if let failure = error as? OwnedProcess.Failure {
      if case .resourceLimit(let detail) = failure {
        return .resourceLimit(detail)
      }
      if let process {
        await handleProcessExit(await process.wait())
      }
      return exitError ?? .serverExited(detail: failure.localizedDescription)
    }
    if let error = error as? MCPClientError {
      return error
    }
    guard let error = error as? MCPError else {
      return .protocolError(error.localizedDescription)
    }

    switch error {
    case .connectionClosed, .transportError:
      return .notConnected
    case .serverError(let code, let message):
      return .serverError(code: code, message: message)
    case .parseError(let detail):
      return .protocolError(detail ?? error.localizedDescription)
    case .invalidRequest, .methodNotFound, .invalidParams, .internalError,
      .urlElicitationRequired:
      return .serverError(code: error.code, message: error.localizedDescription)
    }
  }
}
