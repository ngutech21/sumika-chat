import Foundation
import Testing

@testable import SumikaCore

struct ToolDefinitionSchemaTests {
  @Test
  func registeredToolsHaveStableExecutableMetadata() {
    let definitions = ToolExecutorRegistry.codingAgent.definitions

    #expect(!definitions.isEmpty)

    for definition in definitions {
      #expect(!definition.name.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      #expect(!definition.parameters.isEmpty)

      for parameter in definition.parameters {
        #expect(!parameter.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
    #expect(schema.parameters.properties["limit"]?.maximum == 500)
    #expect(schema.parameters.properties["limit"]?.defaultValue == .number(500))
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
  func writeAndEditDefinitionsExposeSemanticContracts() {
    let writeDefinition = ToolDefinition.writeFile
    let editDefinition = ToolDefinition.editFile

    #expect(
      writeDefinition.description
        == "Create or replace one text file. Use for new files or intentional full-file replacement. Parent directories are created automatically. Do not combine this call with another write_file/edit_file for the same file, including equivalent paths, in one response; wait for its result first."
    )
    #expect(
      writeDefinition.parameters.first { $0.name == "path" }?.description
        == "Workspace-relative file path.")
    #expect(writeDefinition.parameters.first { $0.name == "content" }?.valueType == .string)
    #expect(
      writeDefinition.parameters.first { $0.name == "content" }?.supportsHeredocPayload == true)
    #expect(
      writeDefinition.parameters.first { $0.name == "content" }?.description
        == "Entire file content after this call.")

    #expect(editDefinition.functionSchema.parameters.required == ["path", "old_text", "new_text"])
    #expect(
      editDefinition.description
        == "Replace one unique text span in an existing file. Read first unless the current content is already in context. Multiple edit_file calls may target non-overlapping spans of one current file snapshot; they are approved and applied atomically per file. Do not combine them with write_file for that file."
    )
    #expect(
      editDefinition.parameters.first { $0.name == "path" }?.description
        == "Workspace-relative path to the existing file.")
    #expect(editDefinition.parameters.first { $0.name == "old_text" }?.valueType == .string)
    #expect(
      editDefinition.parameters.first { $0.name == "old_text" }?.supportsHeredocPayload == true)
    #expect(
      editDefinition.parameters.first { $0.name == "old_text" }?.description
        == "Exact current text to replace; it must occur exactly once.")
    #expect(
      editDefinition.parameters.first { $0.name == "new_text" }?.description
        == "Replacement text. Use an empty string to delete the matched span.")
    #expect(
      editDefinition.parameters.first { $0.name == "new_text" }?.supportsHeredocPayload == true)
  }

  @Test
  func runCommandDefinitionExposesApprovalBoundedTimeout() {
    let definition = ToolDefinition.runCommand
    let schema = definition.functionSchema

    #expect(definition.capabilities == [.runCommand])
    #expect(definition.riskLevel == .high)
    #expect(schema.parameters.required == ["command"])
    #expect(schema.parameters.properties["command"]?.type == .string)
    #expect(schema.parameters.properties["timeoutSeconds"]?.type == .integer)
    #expect(schema.parameters.properties["timeoutSeconds"]?.defaultValue == .number(120))
    #expect(schema.parameters.properties["timeoutSeconds"]?.minimum == 1)
    #expect(schema.parameters.properties["timeoutSeconds"]?.maximum == 120)
    #expect(schema.parameters.properties["reason"]?.type == .string)
  }

  @Test
  func todoWriteDefinitionExposesNumberedItemsAndDoneFlags() {
    let definition = ToolDefinition.todoWrite
    let schema = definition.functionSchema

    #expect(definition.riskLevel == .low)
    #expect(definition.capabilities.isEmpty)
    #expect(schema.parameters.required == ["item1", "item2"])
    #expect(schema.parameters.properties["item1"]?.type == .string)
    #expect(schema.parameters.properties["item2"]?.type == .string)
    #expect(schema.parameters.properties["item6"]?.type == .string)
    #expect(schema.parameters.properties["done1"]?.type == .boolean)
    #expect(schema.parameters.properties["done6"]?.type == .boolean)
    #expect(schema.parameters.properties["done1"]?.defaultValue == .bool(false))
    #expect(schema.parameters.properties["item1"]?.arrayItems == nil)
    #expect(schema.parameters.properties.keys.count == 12)
  }

  @Test
  func askUserDefinitionExposesPlainStringOptions() {
    let definition = ToolDefinition.askUser
    let schema = definition.functionSchema

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
  func browserDefinitionsExposePreviewInspectionControls() {
    let refresh = ToolDefinition.browserRefresh
    let inspect = ToolDefinition.browserInspect

    #expect(refresh.riskLevel == .low)
    #expect(refresh.capabilities.isEmpty)
    #expect(refresh.functionSchema.parameters.required.isEmpty)
    #expect(refresh.functionSchema.parameters.properties["hard"]?.type == .boolean)
    #expect(refresh.functionSchema.parameters.properties["hard"]?.defaultValue == .bool(false))

    #expect(inspect.riskLevel == .low)
    #expect(inspect.capabilities.isEmpty)
    #expect(inspect.functionSchema.parameters.required.isEmpty)
    #expect(inspect.functionSchema.parameters.properties["selector"]?.type == .string)
    #expect(inspect.functionSchema.parameters.properties["maxLength"]?.type == .integer)
    #expect(inspect.functionSchema.parameters.properties["maxLength"]?.minimum == 1)
    #expect(inspect.functionSchema.parameters.properties["maxLength"]?.maximum == 20_000)
    #expect(
      inspect.functionSchema.parameters.properties["maxLength"]?.defaultValue == .number(4000))
    #expect(inspect.functionSchema.parameters.properties["includeHtml"]?.type == .boolean)
    #expect(
      inspect.functionSchema.parameters.properties["includeHtml"]?.defaultValue == .bool(false))
  }

  @Test
  func functionSchemaEncodesProviderNeutralFunctionToolShape() throws {
    let data = try JSONEncoder().encode(ToolDefinition.readFile.functionSchema)
    let object = try #require(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )

    #expect(object["type"] as? String == "function")
    #expect(object["name"] as? String == "read_file")

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
    #expect(schema.parameters.properties["path"]?.type == .string)
  }

  @Test
  func toolDefinitionsAreCodable() throws {
    let definitions = ToolExecutorRegistry.codingAgent.definitions

    let data = try JSONEncoder().encode(definitions)
    let decoded = try JSONDecoder().decode([ToolDefinition].self, from: data)

    #expect(decoded == definitions)
  }
}
