import Foundation

public struct ToolParameterDefinition: Equatable, Sendable {
  public var name: String
  public var description: String
  public var isRequired: Bool
  public var supportsHeredocPayload: Bool

  public init(
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

public enum ToolCapability: String, Codable, Equatable, Hashable, Sendable {
  case readWorkspace
  case writeWorkspace
  case runCommand
}

public struct ToolDefinition: Identifiable, Equatable, Sendable {
  public var id: ToolName { name }

  public var name: ToolName
  public var description: String
  public var parameters: [ToolParameterDefinition]
  public var taggedExample: String
  public var capabilities: Set<ToolCapability>
  public var riskLevel: ToolRiskLevel

  public init(
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

public struct ToolRegistry: Equatable, Sendable {
  public var tools: [ToolDefinition]

  public init(tools: [ToolDefinition]) {
    self.tools = tools
  }

  public func definition(for name: ToolName) -> ToolDefinition? {
    tools.first { $0.name == name }
  }

  public func definition(canonicalizing name: String) -> ToolDefinition? {
    definition(for: ToolName(canonicalizing: name))
  }
}

nonisolated extension ToolDefinition {
  public static let readFile = ToolDefinition(
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

  public static let listFiles = ToolDefinition(
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

  public static let globFiles = ToolDefinition(
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

  public static let searchFiles = ToolDefinition(
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

  public static let writeFile = ToolDefinition(
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

  public static let editFile = ToolDefinition(
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
