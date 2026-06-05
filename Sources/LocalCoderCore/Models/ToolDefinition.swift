import Foundation

public enum ToolParameterValueType: String, Codable, Equatable, Sendable {
  case string
  case integer
  case number
  case boolean
  case array
  case object
}

public struct ToolParameterDefinition: Codable, Equatable, Sendable {
  public var name: String
  public var description: String
  public var isRequired: Bool
  public var valueType: ToolParameterValueType
  public var enumValues: [String]?
  public var defaultValue: ToolArgumentValue?
  public var minimum: Double?
  public var maximum: Double?
  public var arrayItems: ToolJSONSchemaObject?
  public var supportsHeredocPayload: Bool

  public init(
    name: String,
    description: String,
    isRequired: Bool,
    valueType: ToolParameterValueType = .string,
    enumValues: [String]? = nil,
    defaultValue: ToolArgumentValue? = nil,
    minimum: Double? = nil,
    maximum: Double? = nil,
    arrayItems: ToolJSONSchemaObject? = nil,
    supportsHeredocPayload: Bool = false
  ) {
    self.name = name
    self.description = description
    self.isRequired = isRequired
    self.valueType = valueType
    self.enumValues = enumValues
    self.defaultValue = defaultValue
    self.minimum = minimum
    self.maximum = maximum
    self.arrayItems = arrayItems
    self.supportsHeredocPayload = supportsHeredocPayload
  }
}

public enum ToolCapability: String, Codable, Equatable, Hashable, Sendable {
  case readWorkspace
  case writeWorkspace
  case runCommand
}

public struct ToolDefinition: Codable, Identifiable, Equatable, Sendable {
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
    precondition(
      Set(parameters.map(\.name)).count == parameters.count,
      "ToolDefinition parameter names must be unique."
    )
    self.name = name
    self.description = description
    self.parameters = parameters
    self.taggedExample = taggedExample
    self.capabilities = capabilities
    self.riskLevel = riskLevel
  }
}

public struct FunctionToolSchema: Codable, Equatable, Sendable {
  public var type: String
  public var name: String
  public var description: String
  public var parameters: ToolJSONSchemaObject
  public var strict: Bool?

  public init(
    type: String = "function",
    name: String,
    description: String,
    parameters: ToolJSONSchemaObject,
    strict: Bool? = nil
  ) {
    self.type = type
    self.name = name
    self.description = description
    self.parameters = parameters
    self.strict = strict
  }
}

public struct ToolJSONSchemaObject: Codable, Equatable, Sendable {
  public var type: String
  public var properties: [String: ToolJSONSchemaProperty]
  public var required: [String]
  public var additionalProperties: Bool

  public init(
    type: String = "object",
    properties: [String: ToolJSONSchemaProperty],
    required: [String],
    additionalProperties: Bool = false
  ) {
    self.type = type
    self.properties = properties
    self.required = required
    self.additionalProperties = additionalProperties
  }

  public init(parameters: [ToolParameterDefinition]) {
    var properties: [String: ToolJSONSchemaProperty] = [:]
    var required: [String] = []

    for parameter in parameters {
      guard properties[parameter.name] == nil else {
        continue
      }

      properties[parameter.name] = ToolJSONSchemaProperty(
        type: parameter.valueType,
        description: parameter.description,
        enumValues: parameter.enumValues,
        defaultValue: parameter.defaultValue,
        minimum: parameter.minimum,
        maximum: parameter.maximum,
        arrayItems: parameter.arrayItems
      )

      if parameter.isRequired {
        required.append(parameter.name)
      }
    }

    self.init(properties: properties, required: required)
  }
}

public struct ToolJSONSchemaProperty: Codable, Equatable, Sendable {
  public var type: ToolParameterValueType
  public var description: String
  public var enumValues: [String]?
  public var defaultValue: ToolArgumentValue?
  public var minimum: Double?
  public var maximum: Double?
  public var arrayItems: ToolJSONSchemaObject?

  private enum CodingKeys: String, CodingKey {
    case type
    case description
    case enumValues = "enum"
    case defaultValue = "default"
    case minimum
    case maximum
    case arrayItems = "items"
  }

  public init(
    type: ToolParameterValueType,
    description: String,
    enumValues: [String]? = nil,
    defaultValue: ToolArgumentValue? = nil,
    minimum: Double? = nil,
    maximum: Double? = nil,
    arrayItems: ToolJSONSchemaObject? = nil
  ) {
    self.type = type
    self.description = description
    self.enumValues = enumValues
    self.defaultValue = defaultValue
    self.minimum = minimum
    self.maximum = maximum
    self.arrayItems = arrayItems
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
  public var functionSchema: FunctionToolSchema {
    FunctionToolSchema(
      name: name.rawValue,
      description: description,
      parameters: ToolJSONSchemaObject(parameters: parameters)
    )
  }

  public static let readFile = ToolDefinition(
    name: .readFile,
    description:
      "Read a workspace text file into model context and return its current content with line numbers. Use this when you need the file content to answer, analyze, or edit. Use workspace-relative paths.",
    parameters: [
      ToolParameterDefinition(
        name: "path",
        description: "Workspace-relative path to the text file to read, e.g. Sources/App.swift.",
        isRequired: true
      ),
      ToolParameterDefinition(
        name: "offset",
        description: "Optional 1-based start line for reading a focused window.",
        isRequired: false,
        valueType: .integer,
        minimum: 1
      ),
      ToolParameterDefinition(
        name: "limit",
        description: "Optional maximum number of lines to return.",
        isRequired: false,
        valueType: .integer,
        minimum: 1
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

  public static let showFile = ToolDefinition(
    name: .showFile,
    description:
      "Display a workspace text file directly to the user. Use this only when the user asks to show, open, print, or display file contents without asking for explanation or analysis. Use workspace-relative paths.",
    parameters: [
      ToolParameterDefinition(
        name: "path",
        description: "Workspace-relative path to the text file to display, e.g. Sources/App.swift.",
        isRequired: true
      ),
      ToolParameterDefinition(
        name: "offset",
        description: "Optional 1-based start line for displaying a focused window.",
        isRequired: false,
        valueType: .integer,
        minimum: 1
      ),
      ToolParameterDefinition(
        name: "limit",
        description: "Optional maximum number of lines to display.",
        isRequired: false,
        valueType: .integer,
        minimum: 1
      ),
    ],
    taggedExample: """
      <action name="show_file">
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
    description:
      "List files inside a workspace directory. Use this to inspect nearby files before choosing a path.",
    parameters: [
      ToolParameterDefinition(
        name: "path",
        description: "Workspace-relative directory path. Defaults to the workspace root.",
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
    description:
      "Find workspace files matching a glob pattern. Use this when the file name or extension is known.",
    parameters: [
      ToolParameterDefinition(
        name: "pattern",
        description: "Glob pattern to match workspace-relative paths, such as **/*.swift.",
        isRequired: true
      ),
      ToolParameterDefinition(
        name: "path",
        description:
          "Optional workspace-relative directory path to search. Defaults to the workspace root.",
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
    description:
      "Search workspace text files for a regex or literal pattern. Use this to find code content before reading or editing a file.",
    parameters: [
      ToolParameterDefinition(
        name: "pattern",
        description:
          "Regex pattern to search for. Invalid regex values are treated as literal text.",
        isRequired: true
      ),
      ToolParameterDefinition(
        name: "path",
        description:
          "Optional workspace-relative directory path to search. Defaults to the workspace root.",
        isRequired: false
      ),
      ToolParameterDefinition(
        name: "include",
        description: "Optional glob filter for file names, such as *.swift.",
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

  public static let workspaceDiff = ToolDefinition(
    name: .workspaceDiff,
    description:
      "Show current workspace changes using Git status and diff. Read-only. Use this after edits to review what changed. Optionally scope to one workspace-relative path.",
    parameters: [
      ToolParameterDefinition(
        name: "path",
        description:
          "Optional workspace-relative path to scope the diff, e.g. Sources/App.swift. Defaults to the whole workspace.",
        isRequired: false
      )
    ],
    taggedExample: """
      <action name="workspace_diff">
      <path>Sources/App.swift</path>
      </action>
      """,
    capabilities: [.readWorkspace],
    riskLevel: .low
  )

  public static let writeFile = ToolDefinition(
    name: .writeFile,
    description:
      "Create or fully overwrite a workspace text file with complete UTF-8 content. Use this for new files or intentional full-file replacement, not for small targeted edits to existing files.",
    parameters: [
      ToolParameterDefinition(
        name: "path",
        description: "Workspace-relative path to create or fully overwrite.",
        isRequired: true
      ),
      ToolParameterDefinition(
        name: "content",
        description: "Complete UTF-8 file content to write. This replaces the entire file.",
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
    description:
      "Edit an existing workspace text file by replacing one exact old_text span with new_text. Use this for targeted changes after reading the current file content; old_text must be copied exactly and match once.",
    parameters: [
      ToolParameterDefinition(
        name: "path",
        description: "Workspace-relative path to the existing file to edit.",
        isRequired: true
      ),
      ToolParameterDefinition(
        name: "old_text",
        description:
          "Exact UTF-8 text copied from the current file content. Include enough surrounding context so it matches exactly once.",
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

  public static let runCommand = ToolDefinition(
    name: .runCommand,
    description:
      "Run a foreground shell command in the active workspace root after explicit user approval. Use this for build, test, lint, and project scripts when structured file tools are not sufficient.",
    parameters: [
      ToolParameterDefinition(
        name: "command",
        description:
          "Exact shell command to run from the workspace root. For destructive commands, prefer explicit workspace-relative operands such as ./tmp and use -- before path operands when supported.",
        isRequired: true
      ),
      ToolParameterDefinition(
        name: "timeoutSeconds",
        description: "Required timeout in seconds. Values are clamped to the supported range.",
        isRequired: true,
        valueType: .integer,
        minimum: 1,
        maximum: 120
      ),
      ToolParameterDefinition(
        name: "reason",
        description: "Optional short reason for running this command.",
        isRequired: false
      ),
    ],
    taggedExample: """
      <action name="run_command">
      <command>just test-core</command>
      <timeoutSeconds>120</timeoutSeconds>
      <reason>Verify the core test suite after the code change.</reason>
      </action>
      """,
    capabilities: [.runCommand],
    riskLevel: .high
  )

  public static let todoWrite = ToolDefinition(
    name: .todoWrite,
    description:
      "Update the current Agent todo plan for multi-step coding tasks. Use only in Agent mode when tracking 2 to 6 short, reviewable steps; keep at most one item inProgress.",
    parameters: [
      ToolParameterDefinition(
        name: "items",
        description:
          "JSON array string with 2 to 6 todo objects. Do not send a single object or a one-item array. Each object must have id, content, and status, for example [{\"id\":\"setup\",\"content\":\"Create project structure\",\"status\":\"inProgress\"},{\"id\":\"verify\",\"content\":\"Run tests\",\"status\":\"pending\"}].",
        isRequired: true,
        valueType: .string,
        supportsHeredocPayload: true
      )
    ],
    taggedExample: """
      <action name="todo_write">
      <items delimiter="LC_PAYLOAD_V1">
      [
        {"id":"inspect","content":"Inspect the affected chat workflow files","status":"completed"},
        {"id":"core","content":"Add todo state and tool plumbing","status":"inProgress"},
        {"id":"verify","content":"Run focused tests","status":"pending"}
      ]
      LC_PAYLOAD_V1
      </items>
      </action>
      """,
    capabilities: [],
    riskLevel: .low
  )
}
