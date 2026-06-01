import Foundation

struct ToolParameterDefinition: Equatable, Sendable {
  var name: String
  var description: String
  var isRequired: Bool
  var supportsHeredocPayload: Bool

  init(
    name: String,
    description: String,
    isRequired: Bool,
    supportsHeredocPayload: Bool = false
  ) {
    self.name = name
    self.description = description
    self.isRequired = isRequired
    self.supportsHeredocPayload = supportsHeredocPayload
  }
}

struct ToolDefinition: Identifiable, Equatable, Sendable {
  var id: ToolName { name }

  var name: ToolName
  var description: String
  var parameters: [ToolParameterDefinition]
  var taggedExample: String

  init(
    name: ToolName,
    description: String,
    parameters: [ToolParameterDefinition],
    taggedExample: String
  ) {
    self.name = name
    self.description = description
    self.parameters = parameters
    self.taggedExample = taggedExample
  }
}

struct ToolRegistry: Equatable, Sendable {
  static let promptTools = ToolRegistry(tools: [.readFile, .listFiles])

  var tools: [ToolDefinition]

  init(tools: [ToolDefinition]) {
    self.tools = tools
  }

  func definition(for name: ToolName) -> ToolDefinition? {
    tools.first { $0.name == name }
  }

  func definition(canonicalizing name: String) -> ToolDefinition? {
    definition(for: ToolName(canonicalizing: name))
  }
}

extension ToolDefinition {
  static let readFile = ToolDefinition(
    name: .readFile,
    description: "Read a text file inside the active workspace.",
    parameters: [
      ToolParameterDefinition(
        name: "path",
        description: "Relative file path inside the workspace.",
        isRequired: true
      )
    ],
    taggedExample: """
      <action name="read_file">
      <path>Sources/AppState.swift</path>
      </action>
      """
  )

  static let listFiles = ToolDefinition(
    name: .listFiles,
    description: "List files inside a workspace directory.",
    parameters: [
      ToolParameterDefinition(
        name: "path",
        description: "Relative directory path inside the workspace. Defaults to workspace root.",
        isRequired: false
      )
    ],
    taggedExample: """
      <action name="list_files">
      <path>.</path>
      </action>
      """
  )
}
