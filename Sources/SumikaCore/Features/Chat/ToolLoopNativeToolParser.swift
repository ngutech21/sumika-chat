import Foundation

nonisolated enum ToolLoopParsedAction: Equatable, Sendable {
  case none
  case toolCalls([ToolCallParseOutput])
}

enum ToolLoopNativeToolParser {
  static func parse(
    _ toolCalls: [ChatRuntimeToolCall],
    policy: ToolCallingPolicy,
    registry: ToolRegistry,
    workspaceID: Workspace.ID,
    sessionID: ChatSession.ID
  ) -> ToolLoopParsedAction {
    let acceptedToolCalls =
      policy.allowsMultipleToolCalls ? toolCalls : Array(toolCalls.prefix(1))
    let resolver = ToolNameResolver()
    var usedRequestIDs = Set<UUID>()

    let outputs = acceptedToolCalls.map { toolCall in
      let resolution = resolver.resolve(toolCall.name, registry: registry)
      let canonicalToolName =
        resolution.canonicalToolName ?? ToolName(rawValue: toolCall.name)
      let request = RawToolCallRequest(
        id: RuntimeToolCallID.uniqueUUID(from: toolCall.id, usedIDs: &usedRequestIDs),
        workspaceID: workspaceID,
        sessionID: sessionID,
        toolName: canonicalToolName,
        arguments: toolCall.arguments,
        originalToolName: originalToolName(from: resolution),
        createdAt: Date()
      )
      return ToolCallParseOutput(
        request: request,
        modelMessage: ToolCallModelMessage(rawRequest: request)
      )
    }
    guard !outputs.isEmpty else {
      return .none
    }
    return .toolCalls(outputs)
  }

  private static func originalToolName(from resolution: ToolNameResolution) -> String? {
    switch resolution {
    case .exact:
      nil
    case .repaired(let original, _, _), .unknown(let original), .ambiguous(let original, _):
      original
    }
  }
}

extension ToolLoopParsedAction {
  var toolName: String? {
    switch self {
    case .none:
      nil
    case .toolCalls(let outputs):
      outputs.map(\.request.toolName.rawValue).joined(separator: ",")
    }
  }
}
