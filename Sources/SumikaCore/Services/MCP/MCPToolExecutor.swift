import Foundation

// MARK: - Tool naming

/// Qualified model-facing names for MCP tools: `mcp__<server-slug>__<tool>`.
/// The prefix keeps external tools collision-free against built-in tool names
/// and lets boundaries recognize MCP calls without a registry lookup.
public enum MCPToolNaming {
  public static let prefix = "mcp__"
  private static let separator = "__"

  public static func qualifiedName(serverSlug: String, remoteToolName: String) -> ToolName {
    ToolName(rawValue: prefix + serverSlug + separator + remoteToolName)
  }

  public static func isQualified(_ name: ToolName) -> Bool {
    name.rawValue.hasPrefix(prefix)
  }
}

// MARK: - Input

public struct MCPToolInput: Codable, Equatable, Sendable {
  public var serverID: UUID
  public var serverName: String
  public var serverSlug: String
  public var remoteToolName: String
  public var arguments: ToolCallArguments

  public init(
    serverID: UUID,
    serverName: String,
    serverSlug: String,
    remoteToolName: String,
    arguments: ToolCallArguments
  ) {
    self.serverID = serverID
    self.serverName = serverName
    self.serverSlug = serverSlug
    self.remoteToolName = remoteToolName
    self.arguments = arguments
  }

  public var qualifiedName: ToolName {
    MCPToolNaming.qualifiedName(serverSlug: serverSlug, remoteToolName: remoteToolName)
  }
}

// MARK: - Result

public enum MCPToolContentBlock: Codable, Equatable, Sendable {
  case text(String)
  case unsupported(type: String)
}

public struct MCPToolResult: Codable, Equatable, Sendable {
  public var serverName: String
  public var remoteToolName: String
  public var content: [MCPToolContentBlock]
  public var isError: Bool
  public var truncated: Bool

  public init(
    serverName: String,
    remoteToolName: String,
    content: [MCPToolContentBlock],
    isError: Bool,
    truncated: Bool = false
  ) {
    self.serverName = serverName
    self.remoteToolName = remoteToolName
    self.content = content
    self.isError = isError
    self.truncated = truncated
  }
}

nonisolated extension MCPToolResult {
  public var renderedText: String {
    guard !content.isEmpty else {
      return isError ? "The MCP tool reported an error without details." : "(empty result)"
    }
    return content.map { block in
      switch block {
      case .text(let text):
        text
      case .unsupported(let type):
        "[unsupported \(type) content omitted]"
      }
    }.joined(separator: "\n\n")
  }

  public var preview: ToolResultPreview {
    ToolResultPreview(
      status: isError ? .failed : .success,
      text: previewText,
      truncated: truncated
    )
  }

  private var previewText: String {
    let header = "MCP tool \(remoteToolName) on \(serverName)"
    guard isError else {
      return "\(header)\n\n\(renderedText)"
    }
    return "\(header) reported an error.\n\n\(renderedText)"
  }
}

// MARK: - Remote tool descriptor

/// One tool as listed by a connected MCP server (`tools/list`).
public struct MCPRemoteTool: Codable, Equatable, Sendable {
  public var name: String
  public var description: String
  public var inputSchema: ToolArgumentValue?

  public init(name: String, description: String, inputSchema: ToolArgumentValue? = nil) {
    self.name = name
    self.description = description
    self.inputSchema = inputSchema
  }
}

// MARK: - Client boundary

public protocol MCPToolCalling: Sendable {
  func callTool(
    serverID: UUID,
    connectionToken: UUID,
    name: String,
    arguments: ToolCallArguments
  ) async throws -> MCPToolResult
}

// MARK: - Executor

/// Dynamic executor for one tool on one configured MCP server. Instances are
/// built at runtime from `tools/list` results; the codec carries the qualified
/// definition so validation, approval, and execution reuse the standard tool
/// runtime state machine.
public struct MCPToolExecutor: DynamicToolExecutor {
  /// Server-provided descriptions are untrusted prompt input; cap them before
  /// they reach the model-facing tool schema.
  static let maxDescriptionLength = 600

  public let codec: ToolCodec<MCPToolInput>
  private let serverID: UUID
  private let connectionToken: UUID
  private let client: any MCPToolCalling

  public init(
    serverID: UUID,
    connectionToken: UUID,
    serverName: String,
    serverSlug: String,
    remoteTool: MCPRemoteTool,
    client: any MCPToolCalling
  ) {
    let definition = ToolDefinition(
      name: MCPToolNaming.qualifiedName(
        serverSlug: serverSlug,
        remoteToolName: remoteTool.name
      ),
      description: Self.cappedDescription(remoteTool.description),
      parameters: [],
      rawParametersSchema: remoteTool.inputSchema.map(MCPToolSchemaNormalizer.normalized),
      capabilities: [.externalService],
      riskLevel: .high
    )
    self.codec = ToolCodec(
      definition: definition,
      decodeArguments: { arguments in
        MCPToolInput(
          serverID: serverID,
          serverName: serverName,
          serverSlug: serverSlug,
          remoteToolName: remoteTool.name,
          arguments: arguments
        )
      },
      makePayload: ToolCallPayload.mcp,
      extractInput: { payload in
        guard case .mcp(let input) = payload else {
          throw ToolInputDecodingError.payloadMismatch(
            expected: MCPToolNaming.qualifiedName(
              serverSlug: serverSlug,
              remoteToolName: remoteTool.name
            ).rawValue,
            actual: payload.toolName.rawValue
          )
        }
        return input
      }
    )
    self.serverID = serverID
    self.connectionToken = connectionToken
    self.client = client
  }

  public func evaluatePermission(
    _ input: MCPToolInput,
    context: ToolContext
  ) -> ToolPermissionEvaluation {
    ToolPermissionEvaluation(
      decision: .requiresApproval,
      reason:
        "External MCP tool \(input.remoteToolName) on \(input.serverName) requires approval before every call.",
      riskLevel: .high
    )
  }

  public func previewApproval(
    _ input: MCPToolInput,
    context: ToolContext
  ) async -> ToolResultPreview? {
    ToolResultPreview(
      status: .success,
      text: """
        MCP tool requires approval
        Server: \(input.serverName)
        Tool: \(input.remoteToolName)
        Arguments:
        \(Self.renderedArguments(input.arguments))
        """
    )
  }

  public func run(_ input: MCPToolInput, context: ToolContext) async -> ToolResultPayload {
    do {
      let result = try await client.callTool(
        serverID: serverID,
        connectionToken: connectionToken,
        name: input.remoteToolName,
        arguments: input.arguments
      )
      return .mcp(result)
    } catch {
      return .failure(
        ToolFailure(
          toolName: input.qualifiedName,
          path: nil,
          reason: .executionError(
            "MCP tool \(input.remoteToolName) on \(input.serverName) failed: \(error.localizedDescription)"
          )
        )
      )
    }
  }

  static func cappedDescription(_ description: String) -> String {
    let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > maxDescriptionLength else {
      return trimmed
    }
    return String(trimmed.prefix(maxDescriptionLength)) + "…"
  }

  private static func renderedArguments(_ arguments: ToolCallArguments) -> String {
    guard !arguments.isEmpty else {
      return "(none)"
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard
      let data = try? encoder.encode(arguments),
      let text = String(data: data, encoding: .utf8)
    else {
      return arguments.keys.sorted().joined(separator: ", ")
    }
    return text
  }
}
