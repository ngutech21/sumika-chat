import Foundation

public enum MCPClientError: LocalizedError, Equatable {
  case notConnected
  case serverExited(detail: String?)
  case timedOut(method: String)
  case protocolError(String)
  case serverError(code: Int, message: String)

  public var errorDescription: String? {
    switch self {
    case .notConnected:
      return "The MCP server is not connected."
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

/// One stdio connection to a configured MCP server.
///
/// Sumika spawns the server process itself (`/usr/bin/env <command> <args>`
/// with the same PATH conventions as `run_command`) and speaks JSON-RPC 2.0
/// over newline-delimited JSON on the child's stdin/stdout, per the MCP stdio
/// transport. v1 protocol surface: `initialize`, `notifications/initialized`,
/// `tools/list` (paginated), and `tools/call`.
public actor MCPServerConnection {
  private enum Timeouts {
    // npx/uvx may download packages on first launch.
    static let initializeSeconds = 30
    static let listToolsSeconds = 30
    static let callToolSeconds = 120
  }

  private static let protocolVersion = "2025-06-18"
  private static let maxToolListPages = 16
  private static let maxResultTextCharacters = 64_000
  private static let stderrTailLimit = 2_048

  private let config: MCPServerConfig
  private let baseEnvironment: [String: String]
  private let pathPrefixDirectories: [URL]

  private var process: Process?
  private var stdinHandle: FileHandle?
  private var stdoutTask: Task<Void, Never>?
  private var stderrTask: Task<Void, Never>?
  private var stderrTail = ""

  private var nextRequestID = 1
  private var pendingRequests: [Int: CheckedContinuation<ToolArgumentValue, any Error>] = [:]
  private var earlyResponses: [Int: Result<ToolArgumentValue, any Error>] = [:]
  private var abandonedRequestIDs: Set<Int> = []
  private var exitError: MCPClientError?

  public init(
    config: MCPServerConfig,
    baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
    pathPrefixDirectories: [URL] = [
      URL(filePath: "/opt/homebrew/bin"),
      URL(filePath: "/usr/local/bin"),
      URL(filePath: "/opt/local/bin"),
    ]
  ) {
    self.config = config
    self.baseEnvironment = baseEnvironment
    self.pathPrefixDirectories = pathPrefixDirectories
  }

  // MARK: - Lifecycle

  /// Spawns the server process, performs the `initialize` handshake, and
  /// returns the server's tools.
  public func start() async throws -> [MCPRemoteTool] {
    guard process == nil else {
      throw MCPClientError.protocolError("Connection was already started.")
    }

    try launchProcess()
    _ = try await sendRequest(
      method: "initialize",
      params: .object([
        "protocolVersion": .string(Self.protocolVersion),
        "capabilities": .object([:]),
        "clientInfo": .object([
          "name": .string("Sumika"),
          "version": .string("1.0"),
        ]),
      ]),
      timeoutSeconds: Timeouts.initializeSeconds
    )
    try sendNotification(method: "notifications/initialized", params: .object([:]))
    return try await listTools()
  }

  public func shutdown() {
    let process = process
    self.process = nil
    stdoutTask?.cancel()
    stderrTask?.cancel()
    try? stdinHandle?.close()
    stdinHandle = nil
    failAllPending(with: exitError ?? .serverExited(detail: nil))
    if let process, process.isRunning {
      terminateProcessTree(process)
    }
  }

  // MARK: - Requests

  public func callTool(name: String, arguments: ToolCallArguments) async throws -> MCPToolResult {
    let result = try await sendRequest(
      method: "tools/call",
      params: .object([
        "name": .string(name),
        "arguments": .object(arguments),
      ]),
      timeoutSeconds: Timeouts.callToolSeconds
    )
    return Self.toolResult(from: result, serverName: config.name, remoteToolName: name)
  }

  private func listTools() async throws -> [MCPRemoteTool] {
    var tools: [MCPRemoteTool] = []
    var cursor: String?
    for _ in 0..<Self.maxToolListPages {
      let params: ToolArgumentValue =
        cursor.map { .object(["cursor": .string($0)]) } ?? .object([:])
      let result = try await sendRequest(
        method: "tools/list",
        params: params,
        timeoutSeconds: Timeouts.listToolsSeconds
      )
      guard case .object(let fields) = result, case .array(let entries)? = fields["tools"]
      else {
        throw MCPClientError.protocolError("tools/list returned no tools array.")
      }
      tools.append(contentsOf: entries.compactMap(Self.remoteTool(from:)))
      guard case .string(let nextCursor)? = fields["nextCursor"], !nextCursor.isEmpty else {
        return tools
      }
      cursor = nextCursor
    }
    return tools
  }

  // MARK: - JSON-RPC plumbing

  private func sendRequest(
    method: String,
    params: ToolArgumentValue,
    timeoutSeconds: Int
  ) async throws -> ToolArgumentValue {
    if let exitError {
      throw exitError
    }
    guard stdinHandle != nil else {
      throw MCPClientError.notConnected
    }

    let id = nextRequestID
    nextRequestID += 1
    try writeMessage(
      .object([
        "jsonrpc": .string("2.0"),
        "id": .number(Double(id)),
        "method": .string(method),
        "params": params,
      ])
    )

    let timeoutTask = Task {
      try? await Task.sleep(for: .seconds(timeoutSeconds))
      guard !Task.isCancelled else {
        return
      }
      self.timeOutRequest(id: id, method: method)
    }
    defer { timeoutTask.cancel() }
    return try await awaitResponse(id: id)
  }

  private func sendNotification(method: String, params: ToolArgumentValue) throws {
    try writeMessage(
      .object([
        "jsonrpc": .string("2.0"),
        "method": .string(method),
        "params": params,
      ])
    )
  }

  private func writeMessage(_ message: ToolArgumentValue) throws {
    guard let stdinHandle else {
      throw MCPClientError.notConnected
    }
    var data = try JSONEncoder().encode(message)
    data.append(0x0A)
    do {
      try stdinHandle.write(contentsOf: data)
    } catch {
      throw exitError ?? MCPClientError.serverExited(detail: stderrTailSnapshot())
    }
  }

  private func awaitResponse(id: Int) async throws -> ToolArgumentValue {
    if let result = earlyResponses.removeValue(forKey: id) {
      return try result.get()
    }
    return try await withCheckedThrowingContinuation { continuation in
      pendingRequests[id] = continuation
    }
  }

  private func deliverResponse(id: Int, result: Result<ToolArgumentValue, any Error>) {
    guard !abandonedRequestIDs.contains(id) else {
      abandonedRequestIDs.remove(id)
      return
    }
    if let continuation = pendingRequests.removeValue(forKey: id) {
      continuation.resume(with: result)
    } else {
      earlyResponses[id] = result
    }
  }

  private func timeOutRequest(id: Int, method: String) {
    guard let continuation = pendingRequests.removeValue(forKey: id) else {
      return
    }
    abandonedRequestIDs.insert(id)
    continuation.resume(throwing: MCPClientError.timedOut(method: method))
  }

  private func failAllPending(with error: MCPClientError) {
    let continuations = pendingRequests.values
    pendingRequests = [:]
    earlyResponses = [:]
    abandonedRequestIDs = []
    for continuation in continuations {
      continuation.resume(throwing: error)
    }
  }

  // MARK: - Process

  private func launchProcess() throws {
    let process = Process()
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()

    process.executableURL = URL(filePath: "/usr/bin/env")
    process.arguments = [config.command] + config.arguments
    process.environment = resolvedEnvironment()
    process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
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
    stdinHandle = stdinPipe.fileHandleForWriting
    stdoutTask = Task { [weak self] in
      for await line in PipeLineStream.lines(from: stdoutPipe.fileHandleForReading) {
        guard let self else {
          return
        }
        await self.handleIncomingLine(line)
      }
      await self?.handleProcessExit()
    }
    stderrTask = Task { [weak self] in
      for await line in PipeLineStream.lines(from: stderrPipe.fileHandleForReading) {
        guard let self else {
          return
        }
        await self.recordStderrLine(line)
      }
    }
  }

  private func resolvedEnvironment() -> [String: String] {
    var resolved = baseEnvironment
    let existingPath = resolved["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    let prefix =
      pathPrefixDirectories
      .map { $0.path(percentEncoded: false) }
      .joined(separator: ":")
    resolved["PATH"] = prefix.isEmpty ? existingPath : prefix + ":" + existingPath
    for (key, value) in config.environment {
      resolved[key] = value
    }
    return resolved
  }

  private func handleProcessExit() async {
    // Claim before suspending: exit is reported both by the termination
    // handler and by stdout reaching EOF.
    guard exitError == nil else {
      return
    }
    exitError = .serverExited(detail: nil)
    // Give the stderr reader a moment to drain the diagnostic tail.
    try? await Task.sleep(for: .milliseconds(50))
    let error = MCPClientError.serverExited(detail: stderrTailSnapshot())
    exitError = error
    failAllPending(with: error)
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

  // MARK: - Incoming messages

  private func handleIncomingLine(_ line: String) {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else {
      return
    }
    guard
      let message = try? JSONDecoder().decode(ToolArgumentValue.self, from: Data(trimmed.utf8)),
      case .object(let fields) = message
    else {
      // Servers occasionally log non-JSON noise to stdout; ignore it instead
      // of tearing the connection down.
      return
    }

    guard case .number(let rawID)? = fields["id"] else {
      // Notification or request from the server; v1 supports neither.
      return
    }
    let id = Int(rawID)

    if case .object(let errorFields)? = fields["error"] {
      let code: Int =
        if case .number(let rawCode)? = errorFields["code"] {
          Int(rawCode)
        } else {
          0
        }
      let message: String =
        if case .string(let text)? = errorFields["message"] {
          text
        } else {
          "unknown error"
        }
      deliverResponse(
        id: id, result: .failure(MCPClientError.serverError(code: code, message: message)))
      return
    }

    deliverResponse(id: id, result: .success(fields["result"] ?? .null))
  }

  // MARK: - Result mapping

  private static func remoteTool(from value: ToolArgumentValue) -> MCPRemoteTool? {
    guard
      case .object(let fields) = value,
      case .string(let name)? = fields["name"],
      !name.isEmpty
    else {
      return nil
    }
    let description: String =
      if case .string(let text)? = fields["description"] {
        text
      } else {
        ""
      }
    return MCPRemoteTool(
      name: name,
      description: description,
      inputSchema: fields["inputSchema"]
    )
  }

  static func toolResult(
    from result: ToolArgumentValue,
    serverName: String,
    remoteToolName: String
  ) -> MCPToolResult {
    guard case .object(let fields) = result else {
      return MCPToolResult(
        serverName: serverName,
        remoteToolName: remoteToolName,
        content: [.unsupported(type: "non-object result")],
        isError: false
      )
    }

    let isError: Bool =
      if case .bool(let flag)? = fields["isError"] {
        flag
      } else {
        false
      }

    var blocks: [MCPToolContentBlock] = []
    var remainingCharacters = maxResultTextCharacters
    var truncated = false
    if case .array(let entries)? = fields["content"] {
      for entry in entries {
        guard case .object(let entryFields) = entry else {
          continue
        }
        let type: String =
          if case .string(let text)? = entryFields["type"] {
            text
          } else {
            "unknown"
          }
        guard type == "text", case .string(let text)? = entryFields["text"] else {
          blocks.append(.unsupported(type: type))
          continue
        }
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
      }
    }

    if blocks.isEmpty, let structured = fields["structuredContent"] {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      if let data = try? encoder.encode(structured),
        let text = String(data: data, encoding: .utf8)
      {
        let limited = String(text.prefix(maxResultTextCharacters))
        blocks.append(.text(limited))
        truncated = truncated || limited.count < text.count
      }
    }

    return MCPToolResult(
      serverName: serverName,
      remoteToolName: remoteToolName,
      content: blocks,
      isError: isError,
      truncated: truncated
    )
  }
}
