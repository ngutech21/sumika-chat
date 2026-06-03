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
      #expect(!definition.taggedExample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
  func writeAndEditDefinitionsExposeSafetyConstraints() {
    let writeDefinition = ToolDefinition.writeFile
    let editDefinition = ToolDefinition.editFile

    #expect(writeDefinition.description.contains("fully overwrite"))
    #expect(writeDefinition.description.contains("not for small targeted edits"))
    #expect(writeDefinition.parameters.first { $0.name == "content" }?.valueType == .string)
    #expect(
      writeDefinition.parameters.first { $0.name == "content" }?.supportsHeredocPayload == true)

    #expect(editDefinition.description.contains("after reading the current file content"))
    #expect(editDefinition.description.contains("old_text must be copied exactly"))
    #expect(editDefinition.functionSchema.parameters.required == ["path", "old_text", "new_text"])
    #expect(editDefinition.parameters.first { $0.name == "old_text" }?.valueType == .string)
    #expect(
      editDefinition.parameters.first { $0.name == "old_text" }?.supportsHeredocPayload == true)
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
        == "Workspace-relative path to the text file to read, e.g. Sources/App.swift.")
  }

  @Test
  func toolDefinitionsAreCodable() throws {
    let definitions = ToolExecutorRegistry.codingAgent.definitions

    let data = try JSONEncoder().encode(definitions)
    let decoded = try JSONDecoder().decode([ToolDefinition].self, from: data)

    #expect(decoded == definitions)
  }
}
