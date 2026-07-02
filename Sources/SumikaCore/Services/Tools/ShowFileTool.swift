import Foundation

public struct ShowFileToolExecutor: TypedToolExecutor {
  public static let codec = ToolCodec<ReadFileInput>(
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

  public init(maxBytes: Int = 40 * 1024) {
    readFileExecutor = ReadFileToolExecutor(maxBytes: maxBytes)
  }

  public func evaluatePermission(
    _ input: ReadFileInput,
    context: ToolContext
  ) -> ToolPermissionEvaluation {
    readFileExecutor.evaluatePermission(input, context: context)
  }

  public func run(_ input: ReadFileInput, context: ToolContext) async -> ToolResultPayload {
    await readFileExecutor.run(input, context: context)
  }
}
