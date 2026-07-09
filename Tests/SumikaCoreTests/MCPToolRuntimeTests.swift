import Foundation
import Testing

@testable import SumikaCore

private struct MCPToolCallingFake: MCPToolCalling {
  var result: MCPToolResult?

  func callTool(
    serverID: UUID,
    name: String,
    arguments: ToolCallArguments
  ) async throws -> MCPToolResult {
    guard let result else {
      throw NSError(
        domain: "MCPToolCallingFake",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "server connection lost"]
      )
    }
    return result
  }
}

struct MCPToolRuntimeTests {
  private let serverID = UUID()
  private let validator = ToolCallRequestValidator()

  private func makeExecutor(
    result: MCPToolResult?,
    inputSchema: ToolArgumentValue? = nil
  ) -> MCPToolExecutor {
    MCPToolExecutor(
      serverID: serverID,
      serverName: "GitHub",
      serverSlug: "github",
      remoteTool: MCPRemoteTool(
        name: "create_issue",
        description: "Create an issue in a repository.",
        inputSchema: inputSchema
      ),
      client: MCPToolCallingFake(result: result)
    )
  }

  private func makeWorkspace() throws -> Workspace {
    let rootURL = FileManager.default.temporaryDirectory
      .appending(path: "sumika-mcp-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    return Workspace(
      name: "Project", rootURL: URL(filePath: Workspace.normalizedPath(for: rootURL)))
  }

  private func rawRequest(
    toolName: ToolName,
    arguments: ToolCallArguments
  ) -> RawToolCallRequest {
    RawToolCallRequest(
      workspaceID: UUID(),
      sessionID: UUID(),
      toolName: toolName,
      arguments: arguments,
      createdAt: Date(timeIntervalSince1970: 1)
    )
  }

  // MARK: - Payload codability

  @Test
  func callPayloadRoundTripsThroughCodable() throws {
    let payload = ToolCallPayload.mcp(
      MCPToolInput(
        serverID: serverID,
        serverName: "GitHub",
        serverSlug: "github",
        remoteToolName: "create_issue",
        arguments: ["title": .string("Bug"), "labels": .array([.string("triage")])]
      )
    )

    let data = try JSONEncoder().encode(payload)
    let decoded = try JSONDecoder().decode(ToolCallPayload.self, from: data)

    #expect(decoded == payload)
    #expect(decoded.toolName.rawValue == "mcp__github__create_issue")
  }

  @Test
  func resultPayloadRoundTripsThroughCodable() throws {
    let payload = ToolResultPayload.mcp(
      MCPToolResult(
        serverName: "GitHub",
        remoteToolName: "create_issue",
        content: [.text("Issue #7 created."), .unsupported(type: "image")],
        isError: false,
        truncated: true
      )
    )

    let data = try JSONEncoder().encode(payload)
    let decoded = try JSONDecoder().decode(ToolResultPayload.self, from: data)

    #expect(decoded == payload)
    #expect(decoded.preview.status == .success)
    #expect(decoded.preview.truncated)
  }

  // MARK: - Validator

  @Test
  func validatorRejectsMCPToolWithoutDynamicCodec() {
    let registry = ToolExecutorRegistry.codingAgent

    let request = validator.validate(
      rawRequest(
        toolName: ToolName(rawValue: "mcp__github__create_issue"),
        arguments: ["title": .string("Bug")]
      ),
      registry: registry.toolRegistry,
      dynamicCodecs: registry.dynamicCodecs
    )

    guard case .invalid(let input) = request.payload else {
      Issue.record("Expected invalid payload, got \(request.payload)")
      return
    }
    #expect(input.reason == .unknownToolName("mcp__github__create_issue"))
  }

  @Test
  func validatorBuildsMCPPayloadFromDynamicCodec() {
    let executor = makeExecutor(result: nil)
    let registry = ToolExecutorRegistry.codingAgent.merging([AnyToolExecutor(dynamic: executor)])

    let request = validator.validate(
      rawRequest(
        toolName: ToolName(rawValue: "mcp__github__create_issue"),
        arguments: ["title": .string("Bug")]
      ),
      registry: registry.toolRegistry,
      dynamicCodecs: registry.dynamicCodecs
    )

    guard case .mcp(let input) = request.payload else {
      Issue.record("Expected mcp payload, got \(request.payload)")
      return
    }
    #expect(input.serverID == serverID)
    #expect(input.remoteToolName == "create_issue")
    #expect(input.arguments == ["title": .string("Bug")])
  }

  @Test
  func validatorEnforcesRequiredParametersFromRawSchema() {
    let schema = ToolArgumentValue.object([
      "type": .string("object"),
      "properties": .object(["title": .object(["type": .string("string")])]),
      "required": .array([.string("title")]),
    ])
    let executor = makeExecutor(result: nil, inputSchema: schema)
    let registry = ToolExecutorRegistry.codingAgent.merging([AnyToolExecutor(dynamic: executor)])

    let missing = validator.validate(
      rawRequest(
        toolName: ToolName(rawValue: "mcp__github__create_issue"),
        arguments: ["body": .string("no title")]
      ),
      registry: registry.toolRegistry,
      dynamicCodecs: registry.dynamicCodecs
    )
    let unknownArgumentsAllowed = validator.validate(
      rawRequest(
        toolName: ToolName(rawValue: "mcp__github__create_issue"),
        arguments: ["title": .string("Bug"), "extra": .bool(true)]
      ),
      registry: registry.toolRegistry,
      dynamicCodecs: registry.dynamicCodecs
    )

    guard case .invalid(let input) = missing.payload else {
      Issue.record("Expected invalid payload, got \(missing.payload)")
      return
    }
    #expect(input.reason == .missingRequiredArgument("title"))
    guard case .mcp = unknownArgumentsAllowed.payload else {
      Issue.record("Expected mcp payload, got \(unknownArgumentsAllowed.payload)")
      return
    }
  }

  // MARK: - Executor state machine

  @Test
  func unapprovedRunPausesInAwaitingApprovalWithPreview() async throws {
    let executor = makeExecutor(result: nil)
    let anyExecutor = AnyToolExecutor(dynamic: executor)
    let registry = ToolExecutorRegistry.codingAgent.merging([anyExecutor])
    let workspace = try makeWorkspace()
    let request = validator.validate(
      rawRequest(
        toolName: ToolName(rawValue: "mcp__github__create_issue"),
        arguments: ["title": .string("Bug")]
      ),
      registry: registry.toolRegistry,
      dynamicCodecs: registry.dynamicCodecs
    )

    let record = await anyExecutor.run(request, context: ToolContext(workspace: workspace))

    #expect(record.status == .awaitingApproval)
    let previewText = record.approvalPreview?.text ?? ""
    #expect(previewText.contains("Server: GitHub"))
    #expect(previewText.contains("Tool: create_issue"))
    #expect(previewText.contains("\"title\""))
  }

  @Test
  func approvedRunReturnsMCPResultPayload() async throws {
    let result = MCPToolResult(
      serverName: "GitHub",
      remoteToolName: "create_issue",
      content: [.text("Issue #7 created.")],
      isError: false
    )
    let anyExecutor = AnyToolExecutor(dynamic: makeExecutor(result: result))
    let registry = ToolExecutorRegistry.codingAgent.merging([anyExecutor])
    let workspace = try makeWorkspace()
    let request = validator.validate(
      rawRequest(
        toolName: ToolName(rawValue: "mcp__github__create_issue"),
        arguments: ["title": .string("Bug")]
      ),
      registry: registry.toolRegistry,
      dynamicCodecs: registry.dynamicCodecs
    )

    let record = await anyExecutor.runApproved(
      request, context: ToolContext(workspace: workspace))

    #expect(record.status == .completed)
    #expect(record.resultPayload == .mcp(result))
  }

  @Test
  func approvedRunMapsClientErrorsToFailedRecord() async throws {
    let anyExecutor = AnyToolExecutor(dynamic: makeExecutor(result: nil))
    let registry = ToolExecutorRegistry.codingAgent.merging([anyExecutor])
    let workspace = try makeWorkspace()
    let request = validator.validate(
      rawRequest(
        toolName: ToolName(rawValue: "mcp__github__create_issue"),
        arguments: ["title": .string("Bug")]
      ),
      registry: registry.toolRegistry,
      dynamicCodecs: registry.dynamicCodecs
    )

    let record = await anyExecutor.runApproved(
      request, context: ToolContext(workspace: workspace))

    #expect(record.status == .failed)
    guard case .failure(let failure)? = record.resultPayload else {
      Issue.record("Expected failure payload, got \(String(describing: record.resultPayload))")
      return
    }
    #expect(
      failure.reason
        == .executionError(
          "MCP tool create_issue on GitHub failed: server connection lost"))
  }

  // MARK: - Registry composition

  @Test
  func mergingKeepsBuiltInExecutorsOnNameCollision() {
    let base = ToolExecutorRegistry.codingAgent
    let collidingDefinitionCount = base.definitions.count

    let merged = base.merging([
      AnyToolExecutor(dynamic: makeExecutor(result: nil)),
      AnyToolExecutor(dynamic: makeExecutor(result: nil)),
    ])

    #expect(merged.definitions.count == collidingDefinitionCount + 1)
    #expect(merged.executor(for: ToolName(rawValue: "mcp__github__create_issue")) != nil)
    #expect(merged.executor(for: .readFile) != nil)
  }

  @Test
  func dynamicCodecsExposeOnlyDynamicExecutors() {
    let registry = ToolExecutorRegistry.codingAgent.merging([
      AnyToolExecutor(dynamic: makeExecutor(result: nil))
    ])

    let codecs = registry.dynamicCodecs

    #expect(codecs.count == 1)
    #expect(codecs[ToolName(rawValue: "mcp__github__create_issue")] != nil)
    #expect(codecs[.readFile] == nil)
  }

  // MARK: - Definition hygiene

  @Test
  func executorDefinitionCarriesQualifiedNameSchemaAndRisk() {
    let schema = ToolArgumentValue.object(["type": .string("object")])
    let executor = makeExecutor(result: nil, inputSchema: schema)

    let definition = executor.codec.definition

    #expect(definition.name.rawValue == "mcp__github__create_issue")
    #expect(definition.rawParametersSchema == schema)
    #expect(definition.riskLevel == .high)
    #expect(definition.capabilities == [.externalService])
  }

  @Test
  func longServerDescriptionsAreCapped() {
    let long = String(repeating: "a", count: 2_000)

    let capped = MCPToolExecutor.cappedDescription(long)

    #expect(capped.count == MCPToolExecutor.maxDescriptionLength + 1)
    #expect(capped.hasSuffix("…"))
  }

  // MARK: - Projection

  @Test
  func successProjectionUsesMCPResultKindAndSummaryBlock() {
    let result = MCPToolResult(
      serverName: "GitHub",
      remoteToolName: "create_issue",
      content: [.text("Issue #7 created.")],
      isError: false
    )
    let request = ToolCallRequest.validated(
      raw: rawRequest(
        toolName: ToolName(rawValue: "mcp__github__create_issue"),
        arguments: ["title": .string("Bug")]
      ),
      payload: .mcp(
        MCPToolInput(
          serverID: serverID,
          serverName: "GitHub",
          serverSlug: "github",
          remoteToolName: "create_issue",
          arguments: ["title": .string("Bug")]
        )
      )
    )

    let projection = ToolResultProjector.project(payload: .mcp(result), request: request)

    #expect(projection.metadata.kind == "mcp_result")
    #expect(projection.observation.status == .success)
    #expect(projection.observation.blocks == [.summary("Issue #7 created.")])
    #expect(
      projection.metadata.fields.contains(
        ToolResultModelMetadataField(name: "server", value: .string("GitHub"))))
  }

  @Test
  func errorProjectionBecomesFailedObservation() {
    let result = MCPToolResult(
      serverName: "GitHub",
      remoteToolName: "create_issue",
      content: [.text("Repository not found.")],
      isError: true
    )
    let request = ToolCallRequest.validated(
      raw: rawRequest(
        toolName: ToolName(rawValue: "mcp__github__create_issue"),
        arguments: [:]
      ),
      payload: .mcp(
        MCPToolInput(
          serverID: serverID,
          serverName: "GitHub",
          serverSlug: "github",
          remoteToolName: "create_issue",
          arguments: [:]
        )
      )
    )

    let projection = ToolResultProjector.project(payload: .mcp(result), request: request)

    #expect(projection.observation.status == .failed)
    #expect(
      projection.display
        == .summary(
          status: .failed,
          text: "Server: GitHub\nTool: create_issue\n\nRepository not found.",
          affectedPaths: []
        ))
  }
}
