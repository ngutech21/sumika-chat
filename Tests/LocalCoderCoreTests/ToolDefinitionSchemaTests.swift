import Foundation
import Testing

@testable import LocalCoderCore

struct ToolDefinitionSchemaTests {
  @Test
  func registeredToolsHaveCompleteModelFacingDescriptions() {
    let definitions = ToolExecutorRegistry.codingAgent.definitions

    #expect(!definitions.isEmpty)

    for definition in definitions {
      #expect(!definition.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      #expect(!definition.exampleArguments.isEmpty)
      #expect(!definition.parameters.isEmpty)

      for parameter in definition.parameters {
        #expect(!parameter.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(!parameter.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
  }

  @Test
  func readFileFunctionSchemaIncludesPaginationTypesAndBounds() {
    let schema = ToolDefinition.readFile.functionSchema

    #expect(schema.type == "function")
    #expect(schema.name == "read_file")
    #expect(schema.parameters.type == "object")
    #expect(schema.parameters.required == ["path"])
    #expect(schema.parameters.additionalProperties == false)
    #expect(schema.parameters.properties["path"]?.type == .string)
    #expect(schema.parameters.properties["offset"]?.type == .integer)
    #expect(schema.parameters.properties["offset"]?.minimum == 1)
    #expect(schema.parameters.properties["limit"]?.type == .integer)
    #expect(schema.parameters.properties["limit"]?.minimum == 1)
  }

  @Test
  func showFileFunctionSchemaMatchesReadFileArguments() {
    let schema = ToolDefinition.showFile.functionSchema

    #expect(schema.type == "function")
    #expect(schema.name == "show_file")
    #expect(schema.parameters.type == "object")
    #expect(schema.parameters.required == ["path"])
    #expect(schema.parameters.additionalProperties == false)
    #expect(schema.parameters.properties["path"]?.type == .string)
    #expect(schema.parameters.properties["offset"]?.type == .integer)
    #expect(schema.parameters.properties["offset"]?.minimum == 1)
    #expect(schema.parameters.properties["limit"]?.type == .integer)
    #expect(schema.parameters.properties["limit"]?.minimum == 1)
  }

  @Test
  func writeAndEditDefinitionsExposeSafetyConstraints() {
    let writeDefinition = ToolDefinition.writeFile
    let editDefinition = ToolDefinition.editFile

    #expect(writeDefinition.description.contains("fully overwrite"))
    #expect(writeDefinition.parameters.first { $0.name == "content" }?.valueType == .string)
    #expect(
      writeDefinition.parameters.first { $0.name == "content" }?.description.contains(
        "Replaces the entire file") == true)
    #expect(
      writeDefinition.parameters.first { $0.name == "content" }?.supportsHeredocPayload == true)

    #expect(editDefinition.description.contains("exact text span"))
    #expect(editDefinition.functionSchema.parameters.required == ["path", "old_text", "new_text"])
    #expect(editDefinition.parameters.first { $0.name == "old_text" }?.valueType == .string)
    #expect(
      editDefinition.parameters.first { $0.name == "old_text" }?.description.contains(
        "Must match once") == true)
    #expect(
      editDefinition.parameters.first { $0.name == "old_text" }?.supportsHeredocPayload == true)
  }

  @Test
  func runCommandDefinitionExposesApprovalBoundedTimeout() {
    let definition = ToolDefinition.runCommand
    let schema = definition.functionSchema

    #expect(definition.description.contains("approved foreground shell command"))
    #expect(definition.capabilities == [.runCommand])
    #expect(definition.riskLevel == .high)
    #expect(schema.parameters.required == ["command", "timeoutSeconds"])
    #expect(schema.parameters.properties["command"]?.type == .string)
    #expect(schema.parameters.properties["timeoutSeconds"]?.type == .integer)
    #expect(schema.parameters.properties["timeoutSeconds"]?.minimum == 1)
    #expect(schema.parameters.properties["timeoutSeconds"]?.maximum == 120)
    #expect(schema.parameters.properties["reason"]?.type == .string)
  }

  @Test
  func todoWriteDefinitionExposesNumberedItemsAndDoneFlags() {
    let definition = ToolDefinition.todoWrite
    let schema = definition.functionSchema

    #expect(definition.description.contains("Agent todo plan"))
    #expect(definition.riskLevel == .low)
    #expect(definition.capabilities.isEmpty)
    #expect(schema.parameters.required == ["item1", "item2"])
    #expect(schema.parameters.properties["item1"]?.type == .string)
    #expect(schema.parameters.properties["item2"]?.type == .string)
    #expect(schema.parameters.properties["item6"]?.type == .string)
    #expect(schema.parameters.properties["done1"]?.type == .boolean)
    #expect(schema.parameters.properties["done6"]?.type == .boolean)
    #expect(schema.parameters.properties["done1"]?.defaultValue == .bool(false))
    #expect(schema.parameters.properties["item1"]?.description.contains("Required") == true)
    #expect(schema.parameters.properties["item3"]?.description.contains("Optional") == true)
    #expect(schema.parameters.properties["item1"]?.arrayItems == nil)
    #expect(schema.parameters.properties.keys.count == 12)
  }

  @Test
  func askUserDefinitionExposesPlainStringOptions() {
    let definition = ToolDefinition.askUser
    let schema = definition.functionSchema

    #expect(definition.description.contains("blocking clarification"))
    #expect(definition.riskLevel == .low)
    #expect(definition.capabilities.isEmpty)
    #expect(schema.parameters.required == ["question", "option1", "option2"])
    #expect(schema.parameters.properties["question"]?.type == .string)
    #expect(schema.parameters.properties["option1"]?.type == .string)
    #expect(schema.parameters.properties["option2"]?.type == .string)
    #expect(schema.parameters.properties["option3"]?.type == .string)
    #expect(schema.parameters.properties["option4"]?.type == .string)
    #expect(schema.parameters.properties["option1"]?.arrayItems == nil)
    #expect(
      schema.parameters.properties.keys.sorted() == [
        "option1", "option2", "option3", "option4", "question",
      ])
  }

  @Test
  func functionSchemaEncodesProviderNeutralFunctionToolShape() throws {
    let data = try JSONEncoder().encode(ToolDefinition.readFile.functionSchema)
    let object = try #require(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )

    #expect(object["type"] as? String == "function")
    #expect(object["name"] as? String == "read_file")
    #expect(object["description"] as? String == ToolDefinition.readFile.description)

    let parameters = try #require(object["parameters"] as? [String: Any])
    #expect(parameters["type"] as? String == "object")
    #expect(parameters["additionalProperties"] as? Bool == false)
    #expect(parameters["required"] as? [String] == ["path"])

    let properties = try #require(parameters["properties"] as? [String: Any])
    let offset = try #require(properties["offset"] as? [String: Any])
    #expect(offset["type"] as? String == "integer")
    #expect(offset["minimum"] as? Double == 1)
  }

  @Test
  func functionSchemaProjectionIgnoresDuplicateParameterNames() {
    var definition = ToolDefinition.readFile
    definition.parameters.append(
      ToolParameterDefinition(
        name: "path",
        description: "Duplicate path parameter.",
        isRequired: true
      ))

    let schema = definition.functionSchema

    #expect(schema.parameters.properties.keys.sorted() == ["limit", "offset", "path"])
    #expect(schema.parameters.required == ["path"])
    #expect(
      schema.parameters.properties["path"]?.description
        == "Workspace-relative file path.")
  }

  @Test
  func functionSchemaDescriptionsStayCompactAndNativeOnly() {
    let definitions = ToolExecutorRegistry.codingAgent.definitions
    let forbiddenFragments = ["delimiter", "heredoc", "LC_PAYLOAD_V1"]

    for definition in definitions {
      let schema = definition.functionSchema
      #expect(schema.description.count <= 80)
      for fragment in forbiddenFragments {
        #expect(!schema.description.contains(fragment))
      }

      for property in schema.parameters.properties.values {
        #expect(property.description.count <= 90)
        for fragment in forbiddenFragments {
          #expect(!property.description.contains(fragment))
        }
      }
    }
  }

  @Test
  func optionalRootScopedPathDescriptionsExposeDefaults() {
    let rootDefaultTools = [
      ToolDefinition.listFiles,
      ToolDefinition.globFiles,
      ToolDefinition.searchFiles,
      ToolDefinition.workspaceDiff,
    ]

    for definition in rootDefaultTools {
      let path = definition.functionSchema.parameters.properties["path"]
      #expect(path?.description.contains("Defaults to root") == true)
    }
  }

  @Test
  func toolDefinitionsAreCodable() throws {
    let definitions = ToolExecutorRegistry.codingAgent.definitions

    let data = try JSONEncoder().encode(definitions)
    let decoded = try JSONDecoder().decode([ToolDefinition].self, from: data)

    #expect(decoded == definitions)
  }
}
