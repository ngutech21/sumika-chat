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
  case accessWeb
}

public struct ToolDefinition: Codable, Identifiable, Equatable, Sendable {
  public var id: ToolName { name }

  public var name: ToolName
  public var description: String
  public var parameters: [ToolParameterDefinition]
  public var exampleArguments: ToolCallArguments
  public var capabilities: Set<ToolCapability>
  public var riskLevel: ToolRiskLevel

  public init(
    name: ToolName,
    description: String,
    parameters: [ToolParameterDefinition],
    exampleArguments: ToolCallArguments,
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
    self.exampleArguments = exampleArguments
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
    description: "Read workspace file lines into context.",
    parameters: [
      ToolParameterDefinition(
        name: "path",
        description: "Workspace-relative file path.",
        isRequired: true
      ),
      ToolParameterDefinition(
        name: "offset",
        description: "1-based start line.",
        isRequired: false,
        valueType: .integer,
        minimum: 1
      ),
      ToolParameterDefinition(
        name: "limit",
        description: "Maximum lines to return.",
        isRequired: false,
        valueType: .integer,
        minimum: 1
      ),
    ],
    exampleArguments: [
      "path": .string("Sources/AppState.swift"),
      "offset": .number(1),
      "limit": .number(200),
    ],
    capabilities: [.readWorkspace],
    riskLevel: .low
  )

  public static let showFile = ToolDefinition(
    name: .showFile,
    description: "Display workspace file lines to the user.",
    parameters: [
      ToolParameterDefinition(
        name: "path",
        description: "Workspace-relative file path.",
        isRequired: true
      ),
      ToolParameterDefinition(
        name: "offset",
        description: "1-based start line.",
        isRequired: false,
        valueType: .integer,
        minimum: 1
      ),
      ToolParameterDefinition(
        name: "limit",
        description: "Maximum lines to display.",
        isRequired: false,
        valueType: .integer,
        minimum: 1
      ),
    ],
    exampleArguments: [
      "path": .string("Sources/AppState.swift"),
      "offset": .number(1),
      "limit": .number(200),
    ],
    capabilities: [.readWorkspace],
    riskLevel: .low
  )

  public static let listFiles = ToolDefinition(
    name: .listFiles,
    description: "List files in a workspace directory.",
    parameters: [
      ToolParameterDefinition(
        name: "path",
        description: "Workspace-relative directory path. Defaults to root.",
        isRequired: false
      )
    ],
    exampleArguments: [
      "path": .string(".")
    ],
    capabilities: [.readWorkspace],
    riskLevel: .low
  )

  public static let globFiles = ToolDefinition(
    name: .globFiles,
    description: "Find workspace files by glob.",
    parameters: [
      ToolParameterDefinition(
        name: "pattern",
        description: "Glob pattern for workspace-relative paths.",
        isRequired: true
      ),
      ToolParameterDefinition(
        name: "path",
        description: "Workspace-relative search directory. Defaults to root.",
        isRequired: false
      ),
    ],
    exampleArguments: [
      "pattern": .string("**/*.swift"),
      "path": .string("."),
    ],
    capabilities: [.readWorkspace],
    riskLevel: .low
  )

  public static let searchFiles = ToolDefinition(
    name: .searchFiles,
    description: "Search workspace text files.",
    parameters: [
      ToolParameterDefinition(
        name: "pattern",
        description: "Regex or literal search pattern.",
        isRequired: true
      ),
      ToolParameterDefinition(
        name: "path",
        description: "Workspace-relative search directory. Defaults to root.",
        isRequired: false
      ),
      ToolParameterDefinition(
        name: "include",
        description: "Glob file-name filter.",
        isRequired: false
      ),
    ],
    exampleArguments: [
      "pattern": .string("ToolDefinition"),
      "path": .string("."),
      "include": .string("*.swift"),
    ],
    capabilities: [.readWorkspace],
    riskLevel: .low
  )

  public static let workspaceDiff = ToolDefinition(
    name: .workspaceDiff,
    description: "Show current Git status and diff.",
    parameters: [
      ToolParameterDefinition(
        name: "path",
        description: "Workspace-relative path to scope the diff. Defaults to root.",
        isRequired: false
      )
    ],
    exampleArguments: [
      "path": .string("Sources/App.swift")
    ],
    capabilities: [.readWorkspace],
    riskLevel: .low
  )

  public static let workspaceDiagnostics = ToolDefinition(
    name: .workspaceDiagnostics,
    description: "Parse diagnostics from command output.",
    parameters: [
      ToolParameterDefinition(
        name: "outputRef",
        description: "Command output ref.",
        isRequired: true
      )
    ],
    exampleArguments: [
      "outputRef": .string("cmd_abc123")
    ],
    capabilities: [.readWorkspace],
    riskLevel: .low
  )

  public static let writeFile = ToolDefinition(
    name: .writeFile,
    description: "Create or fully overwrite a workspace text file.",
    parameters: [
      ToolParameterDefinition(
        name: "path",
        description: "Workspace-relative file path.",
        isRequired: true
      ),
      ToolParameterDefinition(
        name: "content",
        description: "Complete UTF-8 content. Replaces the entire file.",
        isRequired: true,
        supportsHeredocPayload: true
      ),
    ],
    exampleArguments: [
      "path": .string("Sources/AppState.swift"),
      "content": .string("import Foundation\n"),
    ],
    capabilities: [.writeWorkspace],
    riskLevel: .high
  )

  public static let editFile = ToolDefinition(
    name: .editFile,
    description: "Replace one exact text span in an existing workspace file.",
    parameters: [
      ToolParameterDefinition(
        name: "path",
        description: "Workspace-relative existing file path.",
        isRequired: true
      ),
      ToolParameterDefinition(
        name: "old_text",
        description: "Exact current text. Must match once.",
        isRequired: true,
        supportsHeredocPayload: true
      ),
      ToolParameterDefinition(
        name: "new_text",
        description: "Replacement UTF-8 text.",
        isRequired: true,
        supportsHeredocPayload: true
      ),
    ],
    exampleArguments: [
      "path": .string("Sources/AppState.swift"),
      "old_text": .string("let title = \"Old\""),
      "new_text": .string("let title = \"New\""),
    ],
    capabilities: [.writeWorkspace],
    riskLevel: .high
  )

  public static let runCommand = ToolDefinition(
    name: .runCommand,
    description: "Run an approved foreground shell command in the workspace root.",
    parameters: [
      ToolParameterDefinition(
        name: "command",
        description: "Exact shell command to run.",
        isRequired: true
      ),
      ToolParameterDefinition(
        name: "timeoutSeconds",
        description: "Timeout in seconds.",
        isRequired: true,
        valueType: .integer,
        minimum: 1,
        maximum: 120
      ),
      ToolParameterDefinition(
        name: "reason",
        description: "Short reason.",
        isRequired: false
      ),
    ],
    exampleArguments: [
      "command": .string("just test-core"),
      "timeoutSeconds": .number(120),
      "reason": .string("Verify the core test suite after the code change."),
    ],
    capabilities: [.runCommand],
    riskLevel: .high
  )

  public static let todoWrite = ToolDefinition(
    name: .todoWrite,
    description: "Update the Agent todo plan.",
    parameters: [
      ToolParameterDefinition(
        name: "items",
        description:
          "2 to 6 todo rows: content:true|false. false=new, true=done. No numbering/markdown.",
        isRequired: true,
        valueType: .string,
        supportsHeredocPayload: true
      )
    ],
    exampleArguments: [
      "items": .string(
        "Inspect the affected chat workflow files:true\n"
          + "Add todo state and tool plumbing:false\n"
          + "Run focused tests:false"
      )
    ],
    capabilities: [],
    riskLevel: .low
  )

  public static let askUser = ToolDefinition(
    name: .askUser,
    description:
      "Ask the user a blocking clarification with predefined answer options.",
    parameters: [
      ToolParameterDefinition(
        name: "question",
        description: "One concise question for the user. Do not include the answer choices here.",
        isRequired: true
      ),
      ToolParameterDefinition(
        name: "option1",
        description: "First answer option. Plain short string; no numbering or markdown.",
        isRequired: true,
        valueType: .string
      ),
      ToolParameterDefinition(
        name: "option2",
        description: "Second answer option. Plain short string; no numbering or markdown.",
        isRequired: true,
        valueType: .string
      ),
      ToolParameterDefinition(
        name: "option3",
        description: "Optional third answer option. Plain short string.",
        isRequired: false,
        valueType: .string
      ),
      ToolParameterDefinition(
        name: "option4",
        description: "Optional fourth answer option. Plain short string.",
        isRequired: false,
        valueType: .string
      ),
    ],
    exampleArguments: [
      "question": .string("Which implementation should I use?"),
      "option1": .string("Minimal fix"),
      "option2": .string("Broader refactor"),
    ],
    capabilities: [],
    riskLevel: .low
  )

  public static let webSearch = ToolDefinition(
    name: .webSearch,
    description: "Search public web pages without sending workspace contents.",
    parameters: [
      ToolParameterDefinition(
        name: "query",
        description:
          "Public web search query. Do not include private source code, secrets, or full logs.",
        isRequired: true
      ),
      ToolParameterDefinition(
        name: "maxResults",
        description: "Maximum result count.",
        isRequired: false,
        valueType: .integer,
        minimum: 1,
        maximum: Double(WebAccessLimits.maxSearchResultCount)
      ),
    ],
    exampleArguments: [
      "query": .string("Swift URLSession async await timeout"),
      "maxResults": .number(5),
    ],
    capabilities: [.accessWeb],
    riskLevel: .high
  )

  public static let webFetch = ToolDefinition(
    name: .webFetch,
    description: "Fetch public text content from an http or https URL.",
    parameters: [
      ToolParameterDefinition(
        name: "url",
        description:
          "Public http or https URL. Local, private, file, and internal network URLs are blocked.",
        isRequired: true
      ),
      ToolParameterDefinition(
        name: "maxBytes",
        description: "Maximum response bytes to read.",
        isRequired: false,
        valueType: .integer,
        minimum: 1,
        maximum: Double(WebAccessLimits.maxFetchBytes)
      ),
    ],
    exampleArguments: [
      "url": .string(
        "https://www.swift.org/documentation/server/guides/libraries/concurrency-adoption-guidelines.html"
      ),
      "maxBytes": .number(65536),
    ],
    capabilities: [.accessWeb],
    riskLevel: .high
  )
}
