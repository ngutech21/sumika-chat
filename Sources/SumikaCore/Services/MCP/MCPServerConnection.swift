import Foundation
import MCP

#if canImport(Darwin)
  import Darwin
#endif

public enum MCPClientError: LocalizedError, Equatable {
  case notConnected
  case staleConnection
  case serverExited(detail: String?)
  case timedOut(method: String)
  case protocolError(String)
  case serverError(code: Int, message: String)

  public var errorDescription: String? {
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
    case .protocolError(let message):
      return "The MCP server sent an invalid response: \(message)"
    case .serverError(let code, let message):
      return "The MCP server reported an error (\(code)): \(message)"
    }
  }
}

/// One SDK-backed stdio or Streamable HTTP connection to a configured MCP server.
///
/// Sumika owns stdio child processes and transport selection. The MCP SDK owns
/// framing, JSON-RPC, lifecycle negotiation, roots dispatch, and typed requests.
public actor MCPServerConnection {
  typealias HTTPTransportFactory = @Sendable (URL) -> any Transport

  private enum Timeouts {
    // npx/uvx may download packages on first launch.
    static let initializeSeconds = 30
    static let listToolsSeconds = 30
    static let callToolSeconds = 120
  }

  private static let maxToolListPages = 16
  private static let maxResultTextCharacters = 64_000
  private static let stderrTailLimit = 2_048

  private let config: MCPServerConfig
  private let workspaceRootURL: URL
  private let baseEnvironment: [String: String]
  private let pathPrefixDirectories: [URL]
  private let makeHTTPTransport: HTTPTransportFactory

  private var process: Process?
  private var client: Client?
  private var stdinHandle: FileHandle?
  private var stdoutHandle: FileHandle?
  private var stderrHandle: FileHandle?
  private var stderrTask: Task<Void, Never>?
  private var stderrTail = ""
  private var exitError: MCPClientError?
  private var isShuttingDown = false

  public init(
    config: MCPServerConfig,
    workspaceRootURL: URL,
    baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
    pathPrefixDirectories: [URL] = [
      URL(filePath: "/opt/homebrew/bin"),
      URL(filePath: "/usr/local/bin"),
      URL(filePath: "/opt/local/bin"),
    ]
  ) {
    self.config = config
    self.workspaceRootURL = workspaceRootURL.standardizedFileURL.resolvingSymlinksInPath()
    self.baseEnvironment = baseEnvironment
    self.pathPrefixDirectories = pathPrefixDirectories
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
    self.makeHTTPTransport = makeHTTPTransport
  }

  // MARK: - Lifecycle

  /// Creates the configured transport, performs SDK-managed initialization,
  /// and returns the server's tools.
  public func start() async throws -> [MCPRemoteTool] {
    guard process == nil, client == nil else {
      throw MCPClientError.protocolError("Connection was already started.")
    }

    let transport: any Transport
    let exposesWorkspaceRoots: Bool
    switch config.transport {
    case .stdio(let command, let arguments, let environment):
      transport = try launchProcess(
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
      try await connect(client: client, transport: transport)
      return try await listTools(client: client)
    } catch {
      throw await mappedError(error)
    }
  }

  public func shutdown() async {
    isShuttingDown = true
    let process = process
    let client = client
    self.process = nil
    self.client = nil

    await client?.disconnect()
    stderrTask?.cancel()
    stderrTask = nil
    closePipeHandles()

    if let process, process.isRunning {
      terminateProcessTree(process)
    }
  }

  // MARK: - Requests

  public func callTool(name: String, arguments: ToolCallArguments) async throws -> MCPToolResult {
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
        timeoutSeconds: Timeouts.callToolSeconds
      )
      return Self.toolResult(from: result, serverName: config.name, remoteToolName: name)
    } catch {
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
        timeoutSeconds: Timeouts.listToolsSeconds
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
        await client.disconnect()
        throw error
      }
    }
  }

  private func awaitRequest<Output>(
    _ context: RequestContext<Output>,
    client: Client,
    method: String,
    timeoutSeconds: Int
  ) async throws -> Output where Output: Decodable & Sendable {
    try await withThrowingTaskGroup(of: Output.self) { group in
      group.addTask {
        try await context.value
      }
      group.addTask {
        try await Task.sleep(for: .seconds(timeoutSeconds))
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
          try? await client.cancelRequest(
            context.requestID,
            reason: "Sumika stopped waiting for \(method)."
          )
        }
        throw error
      }
    }
  }

  // MARK: - Process

  private func launchProcess(
    command: String,
    arguments: [String],
    environment: [String: String]
  ) throws -> StdioTransport {
    let process = Process()
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    let stdinHandle = stdinPipe.fileHandleForWriting
    let stdoutHandle = stdoutPipe.fileHandleForReading
    let stderrHandle = stderrPipe.fileHandleForReading

    // The child may exit between a lifecycle check and an SDK transport write.
    // Make that race return EPIPE instead of terminating Sumika with SIGPIPE.
    try disableSIGPIPE(on: stdinHandle)

    process.executableURL = URL(filePath: "/usr/bin/env")
    process.arguments = [command] + arguments
    process.environment = resolvedEnvironment(overrides: environment)
    process.currentDirectoryURL = workspaceRootURL
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    process.terminationHandler = { [weak self] _ in
      guard let self else {
        return
      }
      Task { await self.handleProcessExit() }
    }

    try process.run()

    self.process = process
    self.stdinHandle = stdinHandle
    self.stdoutHandle = stdoutHandle
    self.stderrHandle = stderrHandle
    stderrTask = Task { [weak self] in
      for await line in PipeLineStream.lines(from: stderrHandle) {
        guard let self else {
          return
        }
        await self.recordStderrLine(line)
      }
    }

    return StdioTransport(
      input: .init(rawValue: stdoutHandle.fileDescriptor),
      output: .init(rawValue: stdinHandle.fileDescriptor)
    )
  }

  private func disableSIGPIPE(on fileHandle: FileHandle) throws {
    #if canImport(Darwin)
      guard fcntl(fileHandle.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
    #endif
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

  private func handleProcessExit() async {
    guard !isShuttingDown, exitError == nil else {
      return
    }
    exitError = .serverExited(detail: nil)
    // Give the stderr reader a moment to drain the diagnostic tail.
    try? await Task.sleep(for: .milliseconds(50))
    exitError = .serverExited(detail: stderrTailSnapshot())
    await client?.disconnect()
  }

  private func recordStderrLine(_ line: String) {
    stderrTail += line + "\n"
    if stderrTail.count > Self.stderrTailLimit {
      stderrTail = String(stderrTail.suffix(Self.stderrTailLimit))
    }
  }

  private func stderrTailSnapshot() -> String? {
    let trimmed = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func closePipeHandles() {
    try? stdinHandle?.close()
    try? stdoutHandle?.close()
    try? stderrHandle?.close()
    stdinHandle = nil
    stdoutHandle = nil
    stderrHandle = nil
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
    if exitError == nil, let process, !process.isRunning {
      await handleProcessExit()
    }
    if let exitError {
      return exitError
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
