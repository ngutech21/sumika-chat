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
      "Read a workspace text file into your context to inspect, explain, summarize, reason about, or edit it. Use this before editing an existing file unless the exact current content is already visible.",
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
    description:
      "Show a workspace file directly to the user without loading its contents into your model context. Use only when the user wants to view/open the file, not when you need to reason about its contents.",
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
    description:
      "List files and folders in a workspace-relative directory. Use this to explore project structure before choosing a path.",
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
    description:
      "Find workspace files by glob pattern. Use this when the target path or file type is unknown but a filename pattern is known.",
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
    description:
      "Search text contents of workspace files. Use this to locate symbols, strings, errors, or relevant code before reading or editing files.",
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
    description:
      "Extract compiler, linter, and test diagnostics from a previous run_command outputRef. Use after build, test, lint, or typecheck commands to get structured file/line/column errors before editing.",
    parameters: [
      ToolParameterDefinition(
        name: "outputRef",
        description:
          "The outputRef returned by run_command, e.g. cmd_abc123. Must refer to the command whose stdout/stderr should be parsed.",
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
    description:
      "Create a new workspace text file or intentionally replace an entire small file. Prefer edit_file for targeted changes to existing files.",
    parameters: [
      ToolParameterDefinition(
        name: "path",
        description: "Workspace-relative file path.",
        isRequired: true
      ),
      ToolParameterDefinition(
        name: "content",
        description:
          "Complete UTF-8 file content written exactly as provided. Replaces the entire file.",
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
    description:
      "Replace exactly one current text span in an existing workspace file. Call read_file first unless the exact current old_text is visible in the latest context. old_text must be copied verbatim from current file content, match once, and be as small as practical. Do not guess from memory.",
    parameters: [
      ToolParameterDefinition(
        name: "path",
        description: "Workspace-relative existing file path.",
        isRequired: true
      ),
      ToolParameterDefinition(
        name: "old_text",
        description:
          "Exact current file text to replace. Copy verbatim from read_file output or visible current file content. Must match exactly once.",
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
    description:
      "Run an approved foreground shell command in the workspace root. Do not use this to write files when write_file or edit_file can do the change.",
    parameters: [
      ToolParameterDefinition(
        name: "command",
        description: "Exact shell command to run.",
        isRequired: true
      ),
      ToolParameterDefinition(
        name: "timeoutSeconds",
        description: "Timeout in seconds. Defaults to 120 when omitted.",
        isRequired: false,
        valueType: .integer,
        defaultValue: .number(120),
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
    description:
      "Create or update the Agent's compact todo plan for multi-step work. Send the full current plan in one call, not one call per item.",
    parameters: (1...6).map { index in
      ToolParameterDefinition(
        name: "item\(index)",
        description:
          index <= 2
          ? "Todo item \(index) content. Required; 120 characters or fewer."
          : "Optional todo item \(index) content. Omit when unused; 120 characters or fewer.",
        isRequired: index <= 2
      )
    }
      + (1...6).map { index in
        ToolParameterDefinition(
          name: "done\(index)",
          description: "Whether item\(index) is already done. Defaults to false.",
          isRequired: false,
          valueType: .boolean,
          defaultValue: .bool(false)
        )
      },
    exampleArguments: [
      "item1": .string("Inspect the affected chat workflow files"),
      "done1": .bool(true),
      "item2": .string("Add todo state and tool plumbing"),
      "done2": .bool(false),
      "item3": .string("Run focused tests"),
      "done3": .bool(false),
    ],
    capabilities: [],
    riskLevel: .low
  )

  public static let askUser = ToolDefinition(
    name: .askUser,
    description:
      "Ask the user one blocking clarification question with predefined answer options. Use only when workspace inspection cannot resolve the ambiguity and choosing a default would risk wrong changes.",
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

  public static let browserRefresh = ToolDefinition(
    name: .browserRefresh,
    description: "Reload the current HTML preview page.",
    parameters: [
      ToolParameterDefinition(
        name: "hard",
        description: "When true, reload from the original preview file. Defaults to false.",
        isRequired: false,
        valueType: .boolean,
        defaultValue: .bool(false)
      )
    ],
    exampleArguments: [
      "hard": .bool(false)
    ],
    capabilities: [],
    riskLevel: .low
  )

  public static let browserInspect = ToolDefinition(
    name: .browserInspect,
    description: "Inspect text or HTML from the current HTML preview page.",
    parameters: [
      ToolParameterDefinition(
        name: "selector",
        description: "Optional plain CSS selector. Do not wrap the value in extra quotes.",
        isRequired: false,
        valueType: .string
      ),
      ToolParameterDefinition(
        name: "maxLength",
        description: "Maximum characters to return. Defaults to 4000.",
        isRequired: false,
        valueType: .integer,
        defaultValue: .number(4000),
        minimum: 1,
        maximum: 20_000
      ),
      ToolParameterDefinition(
        name: "includeHtml",
        description: "When true, include HTML for the inspected element.",
        isRequired: false,
        valueType: .boolean,
        defaultValue: .bool(false)
      ),
    ],
    exampleArguments: [
      "selector": .string("main"),
      "maxLength": .number(4000),
      "includeHtml": .bool(false),
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
