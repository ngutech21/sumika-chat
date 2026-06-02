import Foundation

nonisolated struct ToolParameterDefinition: Equatable, Sendable {
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

nonisolated enum ToolCapability: String, Codable, Equatable, Hashable, Sendable {
  case readWorkspace
  case writeWorkspace
  case applyPatch
  case runCommand
}

nonisolated struct ToolDefinition: Identifiable, Equatable, Sendable {
  var id: ToolName { name }

  var name: ToolName
  var description: String
  var parameters: [ToolParameterDefinition]
  var taggedExample: String
  var capabilities: Set<ToolCapability>
  var riskLevel: ToolRiskLevel

  init(
    name: ToolName,
    description: String,
    parameters: [ToolParameterDefinition],
    taggedExample: String,
    capabilities: Set<ToolCapability> = [],
    riskLevel: ToolRiskLevel = .low
  ) {
    self.name = name
    self.description = description
    self.parameters = parameters
    self.taggedExample = taggedExample
    self.capabilities = capabilities
    self.riskLevel = riskLevel
  }
}

nonisolated struct ToolRegistry: Equatable, Sendable {
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

nonisolated extension ToolDefinition {
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
      """,
    capabilities: [.readWorkspace],
    riskLevel: .low
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
      """,
    capabilities: [.readWorkspace],
    riskLevel: .low
  )

  static let writeFile = ToolDefinition(
    name: .writeFile,
    description: "Write UTF-8 text content to a file inside the active workspace.",
    parameters: [
      ToolParameterDefinition(
        name: "path",
        description: "Relative file path inside the workspace.",
        isRequired: true
      ),
      ToolParameterDefinition(
        name: "content",
        description: "Complete UTF-8 text content to write to the file.",
        isRequired: true,
        supportsHeredocPayload: true
      ),
    ],
    taggedExample: """
      <action name="write_file">
      <path>Sources/AppState.swift</path>
      <content delimiter="__LOCAL_CODER_PAYLOAD__">
      import Foundation
      __LOCAL_CODER_PAYLOAD__
      </content>
      </action>
      """,
    capabilities: [.writeWorkspace],
    riskLevel: .high
  )
}
