import Foundation

struct ToolCodec<Input: Decodable & Sendable>: Sendable {
  let definition: ToolDefinition

  private let decodeArgumentsHandler: @Sendable (ToolCallArguments) throws -> Input
  private let makePayloadHandler: @Sendable (Input) -> ToolCallPayload
  private let extractInputHandler: @Sendable (ToolCallPayload) throws -> Input

  init(
    definition: ToolDefinition,
    decodeArguments: @escaping @Sendable (ToolCallArguments) throws -> Input,
    makePayload: @escaping @Sendable (Input) -> ToolCallPayload,
    extractInput: @escaping @Sendable (ToolCallPayload) throws -> Input
  ) {
    self.definition = definition
    decodeArgumentsHandler = decodeArguments
    makePayloadHandler = makePayload
    extractInputHandler = extractInput
  }

  init(
    definition: ToolDefinition,
    makePayload: @escaping @Sendable (Input) -> ToolCallPayload,
    extractInput: @escaping @Sendable (ToolCallPayload) throws -> Input,
    validateInput: @escaping @Sendable (Input) throws -> Void = { _ in }
  ) {
    self.init(
      definition: definition,
      decodeArguments: { arguments in
        let input = try ToolInputDecoder.decode(Input.self, from: arguments)
        try validateInput(input)
        return input
      },
      makePayload: makePayload,
      extractInput: extractInput
    )
  }

  func decodeArguments(_ arguments: ToolCallArguments) throws -> Input {
    try decodeArgumentsHandler(arguments)
  }

  func payload(from arguments: ToolCallArguments) throws -> ToolCallPayload {
    try makePayloadHandler(decodeArguments(arguments))
  }

  func input(from payload: ToolCallPayload) throws -> Input {
    try extractInputHandler(payload)
  }
}

struct AnyToolCodec: Sendable {
  let definition: ToolDefinition
  private let payloadHandler: @Sendable (ToolCallArguments) throws -> ToolCallPayload

  init<Input: Decodable & Sendable>(_ codec: ToolCodec<Input>) {
    definition = codec.definition
    payloadHandler = { arguments in
      try codec.payload(from: arguments)
    }
  }

  func payload(from arguments: ToolCallArguments) throws -> ToolCallPayload {
    try payloadHandler(arguments)
  }
}

enum ToolCodecCatalog {
  static let builtIn: [AnyToolCodec] = [
    AnyToolCodec(ReadFileToolExecutor.codec),
    AnyToolCodec(ShowFileToolExecutor.codec),
    AnyToolCodec(ListFilesToolExecutor.codec),
    AnyToolCodec(GlobFilesToolExecutor.codec),
    AnyToolCodec(SearchFilesToolExecutor.codec),
    AnyToolCodec(WorkspaceDiffToolExecutor.codec),
    AnyToolCodec(WorkspaceDiagnosticsToolExecutor.codec),
    AnyToolCodec(BrowserRefreshToolExecutor.codec),
    AnyToolCodec(BrowserInspectToolExecutor.codec),
    AnyToolCodec(EditFileToolExecutor.codec),
    AnyToolCodec(WriteFileToolExecutor.codec),
    AnyToolCodec(RunCommandToolExecutor.codec),
    AnyToolCodec(TodoWriteToolExecutor.codec),
    AnyToolCodec(AskUserToolExecutor.codec),
    AnyToolCodec(FinishTaskToolExecutor.codec),
    AnyToolCodec(WebSearchToolExecutor.codec),
    AnyToolCodec(WebFetchToolExecutor.codec),
  ]

  private static let builtInByName: [ToolName: AnyToolCodec] = Dictionary(
    uniqueKeysWithValues: builtIn.map { codec in
      (codec.definition.name, codec)
    })

  static func builtInCodec(for toolName: ToolName) -> AnyToolCodec? {
    builtInByName[toolName]
  }
}

enum ToolArgumentValidation {
  static func requireNonEmptyPath(_ path: String) throws {
    guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw InvalidToolCallReason.emptyPath
    }
  }

  static func validateOptionalPath(_ path: String?) throws {
    if let path {
      try requireNonEmptyPath(path)
    }
  }

  static func requireNonEmptyString(
    _ value: String,
    name: String,
    expected: String
  ) throws {
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw InvalidToolCallReason.invalidArgumentType(name: name, expected: expected)
    }
  }
}
