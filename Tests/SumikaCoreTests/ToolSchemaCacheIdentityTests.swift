import Testing

@testable import SumikaCore

struct ToolSchemaCacheIdentityTests {
  @Test
  func fingerprintIsStableAndSeparateFromVisibleInstructions() throws {
    let registry = ToolRegistry(tools: [.readFile, .editFile])

    let first = try ToolSchemaCacheIdentity.instructions(
      stableInstructions: "Visible instructions",
      registry: registry
    )
    let second = try ToolSchemaCacheIdentity.instructions(
      stableInstructions: "Visible instructions",
      registry: registry
    )

    #expect(first == second)
    #expect(first.hasPrefix("Visible instructions\n\n[tool-schema-sha256:"))
    #expect(first.hasSuffix("]"))
    let promptPlan = ChatRuntimePromptPlan(
      stableInstructions: "Visible instructions",
      cacheIdentityInstructions: first
    )
    #expect(promptPlan.stableInstructions == "Visible instructions")
    #expect(promptPlan.cacheIdentityInstructions == first)
  }

  @Test
  func fingerprintChangesWhenSameNamedSchemaChanges() throws {
    var changedReadFile = ToolDefinition.readFile
    changedReadFile.description += " Changed model guidance."

    let original = try ToolSchemaCacheIdentity.instructions(
      stableInstructions: "Instructions",
      registry: ToolRegistry(tools: [.readFile])
    )
    let changed = try ToolSchemaCacheIdentity.instructions(
      stableInstructions: "Instructions",
      registry: ToolRegistry(tools: [changedReadFile])
    )

    #expect(original != changed)
  }

  @Test
  func fingerprintPreservesModelFacingToolOrder() throws {
    let readThenEdit = try ToolSchemaCacheIdentity.instructions(
      stableInstructions: "Instructions",
      registry: ToolRegistry(tools: [.readFile, .editFile])
    )
    let editThenRead = try ToolSchemaCacheIdentity.instructions(
      stableInstructions: "Instructions",
      registry: ToolRegistry(tools: [.editFile, .readFile])
    )

    #expect(readThenEdit != editThenRead)
  }

  @Test
  func fingerprintIncludesRawMCPParameterSchema() throws {
    let name = ToolName(rawValue: "dynamic_lookup")
    let firstTool = ToolDefinition(
      name: name,
      description: "Dynamic lookup.",
      parameters: [],
      rawParametersSchema: .object([
        "type": .string("object"),
        "properties": .object(["query": .object(["type": .string("string")])]),
      ])
    )
    let secondTool = ToolDefinition(
      name: name,
      description: "Dynamic lookup.",
      parameters: [],
      rawParametersSchema: .object([
        "type": .string("object"),
        "properties": .object(["query": .object(["type": .string("integer")])]),
      ])
    )

    let first = try ToolSchemaCacheIdentity.instructions(
      stableInstructions: "Instructions",
      registry: ToolRegistry(tools: [firstTool])
    )
    let second = try ToolSchemaCacheIdentity.instructions(
      stableInstructions: "Instructions",
      registry: ToolRegistry(tools: [secondTool])
    )

    #expect(first != second)
  }

  @Test
  func emptyRegistryKeepsOriginalCacheIdentity() throws {
    let instructions = try ToolSchemaCacheIdentity.instructions(
      stableInstructions: "Instructions",
      registry: ToolRegistry(tools: [])
    )

    #expect(instructions == "Instructions")
  }
}
