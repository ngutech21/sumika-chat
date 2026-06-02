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
      ),
      ToolParameterDefinition(
        name: "offset",
        description: "Optional 1-based start line for reading a focused window.",
        isRequired: false
      ),
      ToolParameterDefinition(
        name: "limit",
        description: "Optional maximum number of lines to return.",
        isRequired: false
      ),
    ],
    taggedExample: """
      <action name="read_file">
      <path>Sources/AppState.swift</path>
      <offset>1</offset>
      <limit>200</limit>
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

  static let globFiles = ToolDefinition(
    name: .globFiles,
    description: "Find workspace files matching a glob pattern.",
    parameters: [
      ToolParameterDefinition(
        name: "pattern",
        description: "Required glob pattern such as **/*.swift.",
        isRequired: true
      ),
      ToolParameterDefinition(
        name: "path",
        description:
          "Optional relative directory path inside the workspace. Defaults to workspace root.",
        isRequired: false
      ),
    ],
    taggedExample: """
      <action name="glob_files">
      <pattern>**/*.swift</pattern>
      <path>.</path>
      </action>
      """,
    capabilities: [.readWorkspace],
    riskLevel: .low
  )

  static let searchFiles = ToolDefinition(
    name: .searchFiles,
    description: "Search workspace text files for a regex or literal pattern.",
    parameters: [
      ToolParameterDefinition(
        name: "pattern",
        description: "Required regex pattern. Invalid regex values are treated as literal text.",
        isRequired: true
      ),
      ToolParameterDefinition(
        name: "path",
        description:
          "Optional relative directory path inside the workspace. Defaults to workspace root.",
        isRequired: false
      ),
      ToolParameterDefinition(
        name: "include",
        description: "Optional glob filter such as *.swift.",
        isRequired: false
      ),
    ],
    taggedExample: """
      <action name="search_files">
      <pattern>ToolDefinition</pattern>
      <path>.</path>
      <include>*.swift</include>
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
      <content delimiter="LC_PAYLOAD_V1">
      import Foundation
      LC_PAYLOAD_V1
      </content>
      </action>
      """,
    capabilities: [.writeWorkspace],
    riskLevel: .high
  )

  static let editFile = ToolDefinition(
    name: .editFile,
    description: "Replace one exact text span in a UTF-8 workspace file.",
    parameters: [
      ToolParameterDefinition(
        name: "path",
        description: "Relative file path inside the workspace.",
        isRequired: true
      ),
      ToolParameterDefinition(
        name: "old_text",
        description: "Exact UTF-8 text to replace. Must match exactly once.",
        isRequired: true,
        supportsHeredocPayload: true
      ),
      ToolParameterDefinition(
        name: "new_text",
        description: "Replacement UTF-8 text. Must be different from old_text.",
        isRequired: true,
        supportsHeredocPayload: true
      ),
    ],
    taggedExample: """
      <action name="edit_file">
      <path>Sources/AppState.swift</path>
      <old_text delimiter="LC_PAYLOAD_V1">
      let title = "Old"
      LC_PAYLOAD_V1
      </old_text>
      <new_text delimiter="LC_PAYLOAD_V1">
      let title = "New"
      LC_PAYLOAD_V1
      </new_text>
      </action>
      """,
    capabilities: [.writeWorkspace],
    riskLevel: .high
  )
}
