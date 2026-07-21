nonisolated extension ToolDefinition {
  package static let showFile = ToolDefinition(
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
    capabilities: [.readWorkspace],
    riskLevel: .low
  )
}

struct ShowFileToolExecutor: TypedToolExecutor {
  static let codec = ToolCodec<ReadFileInput>(
    definition: ToolDefinition.showFile,
    decodeArguments: ReadFileInput.decodeToolArguments,
    makePayload: ToolCallPayload.showFile,
    extractInput: { payload in
      guard case .showFile(let input) = payload else {
        throw ToolInputDecodingError.payloadMismatch(
          expected: ToolDefinition.showFile.name.rawValue,
          actual: payload.toolName.rawValue
        )
      }
      return input
    }
  )

  private let readFileExecutor: ReadFileToolExecutor

  init(maxBytes: Int = 40 * 1024) {
    readFileExecutor = ReadFileToolExecutor(maxBytes: maxBytes)
  }

  func evaluatePermission(
    _ input: ReadFileInput,
    context: ToolContext
  ) -> ToolPermissionEvaluation {
    readFileExecutor.evaluatePermission(input, context: context)
  }

  func run(_ input: ReadFileInput, context: ToolContext) async -> ToolResultPayload {
    await readFileExecutor.run(input, context: context)
  }
}
