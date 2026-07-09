import Foundation
import Testing

@testable import SumikaCore

struct MCPToolSchemaNormalizerTests {
  @Test
  func collapsesPydanticOptionalAnyOfToNullableType() {
    // Exact shape mcp-server-git emits for git_log.start_timestamp.
    let schema = ToolArgumentValue.object([
      "type": .string("object"),
      "properties": .object([
        "start_timestamp": .object([
          "anyOf": .array([
            .object(["type": .string("string")]),
            .object(["type": .string("null")]),
          ]),
          "default": .null,
          "description": .string("Start timestamp for filtering commits"),
          "title": .string("Start Timestamp"),
        ])
      ]),
      "required": .array([.string("repo_path")]),
    ])

    let normalized = MCPToolSchemaNormalizer.normalized(schema)

    guard
      case .object(let fields) = normalized,
      case .object(let properties)? = fields["properties"],
      case .object(let property)? = properties["start_timestamp"]
    else {
      Issue.record("Expected object schema, got \(normalized)")
      return
    }
    #expect(property["type"] == .string("string"))
    #expect(property["nullable"] == .bool(true))
    #expect(property["anyOf"] == nil)
    #expect(property["description"] == .string("Start timestamp for filtering commits"))
    #expect(fields["required"] == .array([.string("repo_path")]))
  }

  @Test
  func collapsesTypeArraysToFirstNonNullType() {
    let schema = ToolArgumentValue.object([
      "type": .string("object"),
      "properties": .object([
        "count": .object(["type": .array([.string("integer"), .string("null")])])
      ]),
    ])

    let normalized = MCPToolSchemaNormalizer.normalized(schema)

    guard
      case .object(let fields) = normalized,
      case .object(let properties)? = fields["properties"],
      case .object(let property)? = properties["count"]
    else {
      Issue.record("Expected object schema, got \(normalized)")
      return
    }
    #expect(property["type"] == .string("integer"))
    #expect(property["nullable"] == .bool(true))
  }

  @Test
  func addsStringFallbackTypeForUntypedProperties() {
    let schema = ToolArgumentValue.object([
      "type": .string("object"),
      "properties": .object([
        "note": .object(["description": .string("Free-form note.")])
      ]),
    ])

    let normalized = MCPToolSchemaNormalizer.normalized(schema)

    guard
      case .object(let fields) = normalized,
      case .object(let properties)? = fields["properties"],
      case .object(let property)? = properties["note"]
    else {
      Issue.record("Expected object schema, got \(normalized)")
      return
    }
    #expect(property["type"] == .string("string"))
    #expect(property["nullable"] == nil)
  }

  @Test
  func normalizesNestedItemsAndObjectProperties() {
    let schema = ToolArgumentValue.object([
      "type": .string("object"),
      "properties": .object([
        "filters": .object([
          "type": .string("array"),
          "items": .object([
            "type": .string("object"),
            "properties": .object([
              "state": .object([
                "anyOf": .array([
                  .object(["type": .string("string")]),
                  .object(["type": .string("null")]),
                ])
              ])
            ]),
          ]),
        ])
      ]),
    ])

    let normalized = MCPToolSchemaNormalizer.normalized(schema)

    guard
      case .object(let fields) = normalized,
      case .object(let properties)? = fields["properties"],
      case .object(let filters)? = properties["filters"],
      case .object(let items)? = filters["items"],
      case .object(let itemProperties)? = items["properties"],
      case .object(let state)? = itemProperties["state"]
    else {
      Issue.record("Expected nested schema, got \(normalized)")
      return
    }
    #expect(state["type"] == .string("string"))
    #expect(state["nullable"] == .bool(true))
  }

  @Test
  func leavesPlainSchemasUntouched() {
    let schema = ToolArgumentValue.object([
      "type": .string("object"),
      "properties": .object([
        "repo_path": .object([
          "type": .string("string"),
          "title": .string("Repo Path"),
        ])
      ]),
      "required": .array([.string("repo_path")]),
    ])

    let normalized = MCPToolSchemaNormalizer.normalized(schema)

    #expect(normalized == schema)
  }

  @Test
  func executorAppliesNormalizationToDefinitionSchema() {
    let executor = MCPToolExecutor(
      serverID: UUID(),
      serverName: "Git",
      serverSlug: "git",
      remoteTool: MCPRemoteTool(
        name: "git_log",
        description: "Show commit logs.",
        inputSchema: .object([
          "type": .string("object"),
          "properties": .object([
            "start_timestamp": .object([
              "anyOf": .array([
                .object(["type": .string("string")]),
                .object(["type": .string("null")]),
              ])
            ])
          ]),
        ])
      ),
      client: NoopMCPToolCalling()
    )

    guard
      case .object(let fields)? = executor.codec.definition.rawParametersSchema,
      case .object(let properties)? = fields["properties"],
      case .object(let property)? = properties["start_timestamp"]
    else {
      Issue.record("Expected normalized schema on definition")
      return
    }
    #expect(property["type"] == .string("string"))
    #expect(property["nullable"] == .bool(true))
  }
}

private struct NoopMCPToolCalling: MCPToolCalling {
  func callTool(
    serverID: UUID,
    name: String,
    arguments: ToolCallArguments
  ) async throws -> MCPToolResult {
    MCPToolResult(serverName: "Git", remoteToolName: name, content: [], isError: false)
  }
}
