import Foundation
import MLXLMCommon
import Testing

@testable import SumikaCore
@testable import SumikaRuntimeMLX

#if canImport(SumikaTestSupport)
  import SumikaTestSupport
#endif
@Suite()
struct MLXToolMapperTests {
  @Test
  func nativeMLXToolContextMapsRegistryToMLXToolSpecs() throws {
    let toolContext = ChatRuntimeToolContext(
      registry: ToolExecutorRegistry.readOnly.toolRegistry
    )

    let specs = try #require(MLXToolMapper.toolSpecs(from: toolContext))
    let readFileSpec = try #require(
      specs.first { spec in
        let function = spec["function"] as? [String: any Sendable]
        return function?["name"] as? String == "read_file"
      })
    let function = try #require(readFileSpec["function"] as? [String: any Sendable])
    let parameters = try #require(function["parameters"] as? [String: any Sendable])
    let properties = try #require(parameters["properties"] as? [String: any Sendable])
    let path = try #require(properties["path"] as? [String: any Sendable])
    let limit = try #require(properties["limit"] as? [String: any Sendable])

    #expect(readFileSpec["type"] as? String == "function")
    #expect(parameters["type"] as? String == "object")
    #expect(parameters["additionalProperties"] as? Bool == false)
    #expect(path["type"] as? String == "string")
    #expect(limit["type"] as? String == "integer")
  }

  @Test
  func nativeMLXFinishTaskSchemaIsClosedRequiredAndAgentOnly() throws {
    let agentContext = ChatRuntimeToolContext(
      registry: ToolExecutorRegistry.codingAgentRegistry(todoWriteEnabled: false).toolRegistry
    )

    let agentSpecs = try #require(MLXToolMapper.toolSpecs(from: agentContext))
    let finishSpec = try #require(
      agentSpecs.first { spec in
        let function = spec["function"] as? [String: any Sendable]
        return function?["name"] as? String == ToolName.finishTask.rawValue
      })
    let function = try #require(finishSpec["function"] as? [String: any Sendable])
    let parameters = try #require(function["parameters"] as? [String: any Sendable])
    let properties = try #require(parameters["properties"] as? [String: any Sendable])
    let status = try #require(properties["status"] as? [String: any Sendable])
    let summary = try #require(properties["summary"] as? [String: any Sendable])

    #expect(parameters["additionalProperties"] as? Bool == false)
    #expect(parameters["required"] as? [String] == ["status", "summary"])
    #expect(status["type"] as? String == "string")
    #expect(status["enum"] as? [String] == ["done", "blocked", "needs_user"])
    #expect(summary["type"] as? String == "string")

    let chatWebContext = ChatRuntimeToolContext(
      registry: ToolExecutorRegistry.chatWeb.toolRegistry
    )
    let chatWebSpecs = try #require(MLXToolMapper.toolSpecs(from: chatWebContext))
    #expect(
      chatWebSpecs.contains { spec in
        let function = spec["function"] as? [String: any Sendable]
        return function?["name"] as? String == ToolName.finishTask.rawValue
      } == false)
  }

  @Test
  func nativeMLXNilToolContextProducesNoToolSpecs() {
    #expect(MLXToolMapper.toolSpecs(from: nil) == nil)
  }

  @Test
  func nativeMLXToolContextPassesRawParametersSchemaThroughVerbatim() throws {
    let rawSchema = ToolArgumentValue.object([
      "type": .string("object"),
      "properties": .object([
        "filter": .object([
          "type": .string("object"),
          "properties": .object([
            "state": .object([
              "type": .string("string"),
              "enum": .array([.string("open"), .string("closed")]),
            ])
          ]),
        ])
      ]),
      "required": .array([.string("filter")]),
    ])
    let definition = ToolDefinition(
      name: ToolName(rawValue: "mcp__github__list_issues"),
      description: "List issues.",
      parameters: [],
      rawParametersSchema: rawSchema,
      capabilities: [.externalService],
      riskLevel: .high
    )
    let toolContext = ChatRuntimeToolContext(registry: ToolRegistry(tools: [definition]))

    let specs = try #require(MLXToolMapper.toolSpecs(from: toolContext))
    let function = try #require(specs.first?["function"] as? [String: any Sendable])
    let parameters = try #require(function["parameters"] as? [String: any Sendable])
    let properties = try #require(parameters["properties"] as? [String: any Sendable])
    let filter = try #require(properties["filter"] as? [String: any Sendable])
    let filterProperties = try #require(filter["properties"] as? [String: any Sendable])
    let state = try #require(filterProperties["state"] as? [String: any Sendable])

    #expect(function["name"] as? String == "mcp__github__list_issues")
    #expect(parameters["required"] as? [String] == ["filter"])
    #expect(filter["type"] as? String == "object")
    #expect(state["enum"] as? [String] == ["open", "closed"])
  }

  @Test
  func nativeMLXToolContextDropsNullValuesFromRawSchema() throws {
    // pydantic-based MCP servers (e.g. mcp-server-git) emit `"default": null`;
    // the Jinja chat-template engine cannot convert NSNull, so nulls must not
    // survive the ToolSpec mapping.
    let rawSchema = ToolArgumentValue.object([
      "type": .string("object"),
      "properties": .object([
        "start_timestamp": .object([
          "type": .string("string"),
          "default": .null,
        ])
      ]),
    ])
    let definition = ToolDefinition(
      name: ToolName(rawValue: "mcp__git__git_log"),
      description: "Show commit logs.",
      parameters: [],
      rawParametersSchema: rawSchema,
      capabilities: [.externalService],
      riskLevel: .high
    )
    let toolContext = ChatRuntimeToolContext(registry: ToolRegistry(tools: [definition]))

    let specs = try #require(MLXToolMapper.toolSpecs(from: toolContext))
    let function = try #require(specs.first?["function"] as? [String: any Sendable])
    let parameters = try #require(function["parameters"] as? [String: any Sendable])
    let properties = try #require(parameters["properties"] as? [String: any Sendable])
    let startTimestamp = try #require(properties["start_timestamp"] as? [String: any Sendable])

    #expect(startTimestamp["type"] as? String == "string")
    #expect(startTimestamp.keys.contains("default") == false)
    #expect(containsNSNull(parameters) == false)
  }

  private func containsNSNull(_ value: Any) -> Bool {
    if value is NSNull {
      return true
    }
    if let dict = value as? [String: Any] {
      return dict.values.contains(where: containsNSNull(_:))
    }
    if let array = value as? [Any] {
      return array.contains(where: containsNSNull(_:))
    }
    return false
  }

  @Test
  func nativeMLXToolContextDefinesSimpleParametersAsStrings() throws {
    let toolContext = ChatRuntimeToolContext(
      registry: ToolExecutorRegistry.codingAgent.toolRegistry
    )

    let specs = try #require(MLXToolMapper.toolSpecs(from: toolContext))
    let todoSpec = try #require(
      specs.first { spec in
        let function = spec["function"] as? [String: any Sendable]
        return function?["name"] as? String == "todo_write"
      })
    let function = try #require(todoSpec["function"] as? [String: any Sendable])
    let parameters = try #require(function["parameters"] as? [String: any Sendable])
    let properties = try #require(parameters["properties"] as? [String: any Sendable])
    let item1 = try #require(properties["item1"] as? [String: any Sendable])
    let item2 = try #require(properties["item2"] as? [String: any Sendable])
    let done1 = try #require(properties["done1"] as? [String: any Sendable])
    let askSpec = try #require(
      specs.first { spec in
        let function = spec["function"] as? [String: any Sendable]
        return function?["name"] as? String == "ask_user"
      })
    let askFunction = try #require(askSpec["function"] as? [String: any Sendable])
    let askParameters = try #require(askFunction["parameters"] as? [String: any Sendable])
    let askProperties = try #require(askParameters["properties"] as? [String: any Sendable])
    let option1 = try #require(askProperties["option1"] as? [String: any Sendable])
    let option2 = try #require(askProperties["option2"] as? [String: any Sendable])

    #expect(item1["type"] as? String == "string")
    #expect(item1["items"] == nil)
    #expect(item2["type"] as? String == "string")
    #expect(item2["items"] == nil)
    #expect(done1["type"] as? String == "boolean")
    #expect(done1["items"] == nil)
    #expect(option1["type"] as? String == "string")
    #expect(option1["items"] == nil)
    #expect(option2["type"] as? String == "string")
    #expect(option2["items"] == nil)
  }

  @Test
  func mlxToolCallMapsToRuntimeToolCallArguments() {
    let mlxToolCall = MLXLMCommon.ToolCall(
      function: .init(
        name: "read_file",
        arguments: [
          "path": .string("README.md"),
          "limit": .int(20),
          "include_hidden": .bool(false),
        ]
      )
    )

    var usedIDs = Set<UUID>()
    let runtimeToolCall = MLXToolMapper.chatRuntimeToolCall(
      from: mlxToolCall,
      usedIDs: &usedIDs
    )

    #expect(runtimeToolCall.name == "read_file")
    #expect(runtimeToolCall.arguments["path"] == .string("README.md"))
    #expect(runtimeToolCall.arguments["limit"] == .number(20))
    #expect(runtimeToolCall.arguments["include_hidden"] == .bool(false))
  }

}
