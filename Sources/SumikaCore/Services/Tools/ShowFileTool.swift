import Foundation

public struct ShowFileToolExecutor: TypedToolExecutor {
  public static let definition = ToolDefinition.showFile

  private let readFileExecutor: ReadFileToolExecutor

  public init(maxBytes: Int = 40 * 1024) {
    readFileExecutor = ReadFileToolExecutor(maxBytes: maxBytes)
  }

  public static func input(from payload: ToolCallPayload) throws -> ReadFileInput {
    guard case .showFile(let input) = payload else {
      throw ToolInputDecodingError.payloadMismatch(
        expected: definition.name.rawValue,
        actual: payload.toolName.rawValue
      )
    }
    return input
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
