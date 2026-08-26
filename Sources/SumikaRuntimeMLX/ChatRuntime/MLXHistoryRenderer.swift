import CoreImage
import MLXLMCommon
import SumikaCore

struct MLXGenerationInput {
  let historySnapshot: [ProviderPromptMessage]
  let promptSnapshot: [ProviderPromptMessage]
  let images: [UserInput.Image]
  let supportsHistoricalReasoningPreservation: Bool
  let additionalContext: [String: any Sendable]

  var history: [Chat.Message] {
    MLXHistoryRenderer.chatMessages(
      from: historySnapshot,
      supportsHistoricalReasoningPreservation: supportsHistoricalReasoningPreservation
    )
  }
}

enum MLXHistoryRenderer {
  /// Full history keeps the rendered transcript append-only so the cached
  /// KV prefix stays a byte-stable prefix of every later generation. Receipt
  /// compaction rewrites past observations and would invalidate the cache
  /// after every tool turn.
  static let runtimeProjectionMode = ModelContextProjectionMode.fullHistory

  static func imageInputs(
    from attachments: [ChatAttachment],
    attachmentStore: ChatAttachmentStore = ChatAttachmentStore()
  ) throws -> [UserInput.Image] {
    try attachments.map { attachment in
      let url = try attachmentStore.validateStoredFile(for: attachment)
      guard
        let image = CIImage(
          contentsOf: url,
          options: [.applyOrientationProperty: true]
        )
      else {
        throw MLXChatRuntimeError.unreadableImageAttachment(attachment.displayName)
      }
      return .ciImage(image)
    }
  }

  static func imageTypes(from attachments: [ChatAttachment]) -> [String]? {
    let types = attachments.compactMap(\.mimeType)
    return types.isEmpty ? nil : types
  }

  static func imageByteCount(from attachments: [ChatAttachment]) -> Int? {
    let byteCount = attachments.filter { $0.kind == .image }.reduce(0) { total, attachment in
      total + attachment.byteSize
    }
    return byteCount == 0 ? nil : byteCount
  }

  static func runtimeHistoryMessages(
    systemPrompt: String,
    history: [Chat.Message]
  ) throws -> [Chat.Message] {
    let normalizedSystemPrompt = ModelFacingPromptRenderer.normalizedSystemPrompt(systemPrompt)
    let messages =
      if let normalizedSystemPrompt {
        [Chat.Message.system(normalizedSystemPrompt)] + history
      } else {
        history
      }
    return try validatedTemplateMessages(messages, allowsSystemPrompt: true)
  }

  static func generationInput(
    from transcript: ModelPromptProjection,
    images: [UserInput.Image] = [],
    reasoningSelection: ReasoningSelection = .on,
    supportsHistoricalReasoningPreservation: Bool = false
  ) throws -> MLXGenerationInput {
    guard let segments = ProviderPromptProjection.generationSegments(from: transcript) else {
      throw MLXChatRuntimeError.missingUserMessage
    }
    let historySnapshot = segments.history.messages
    let promptSnapshot = segments.prompt.messages

    _ = try validatedChatMessages(
      from: historySnapshot,
      supportsHistoricalReasoningPreservation: supportsHistoricalReasoningPreservation
    )
    let additionalContext = chatTemplateAdditionalContext(
      reasoningSelection: reasoningSelection,
      supportsHistoricalReasoningPreservation: supportsHistoricalReasoningPreservation
    )

    return MLXGenerationInput(
      historySnapshot: historySnapshot,
      promptSnapshot: promptSnapshot,
      images: images,
      supportsHistoricalReasoningPreservation: supportsHistoricalReasoningPreservation,
      additionalContext: additionalContext
    )
  }

  static func chatMessages(
    from snapshots: [ProviderPromptMessage],
    images: [UserInput.Image] = [],
    supportsHistoricalReasoningPreservation: Bool
  ) -> [Chat.Message] {
    var messages: [Chat.Message] = snapshots.map { snapshot -> Chat.Message in
      switch snapshot.role {
      case Chat.Message.Role.assistant.rawValue:
        return .assistant(
          assistantContent(
            from: snapshot,
            supportsHistoricalReasoningPreservation:
              supportsHistoricalReasoningPreservation
          ),
          toolCalls: snapshot.toolCalls.isEmpty
            ? nil
            : snapshot.toolCalls.map(mlxToolCall(from:))
        )
      case Chat.Message.Role.tool.rawValue:
        return .tool(snapshot.content, id: snapshot.toolCallID)
      case Chat.Message.Role.system.rawValue:
        return .system(snapshot.content)
      default:
        return .user(snapshot.content)
      }
    }
    if !images.isEmpty,
      let userIndex = messages.lastIndex(where: { $0.role == .user })
    {
      messages[userIndex].images = images
    }
    return messages
  }

  private static func validatedTemplateMessages(
    _ messages: [Chat.Message],
    allowsSystemPrompt: Bool = false
  ) throws -> [Chat.Message] {
    let bodyMessages: ArraySlice<Chat.Message>
    if messages.first?.role == .system {
      guard allowsSystemPrompt else {
        throw MLXChatRuntimeError.invalidChatTemplateMessageSequence
      }
      bodyMessages = messages.dropFirst()
    } else {
      bodyMessages = messages[...]
    }

    guard bodyMessages.allSatisfy({ $0.role == .user || $0.role == .assistant || $0.role == .tool })
    else {
      throw MLXChatRuntimeError.invalidChatTemplateMessageSequence
    }

    for index in bodyMessages.indices.dropFirst() {
      let previousIndex = bodyMessages.index(before: index)
      let previousRole = bodyMessages[previousIndex].role
      let currentRole = bodyMessages[index].role
      if previousRole == currentRole, currentRole != .tool {
        throw MLXChatRuntimeError.invalidChatTemplateMessageSequence
      }
    }

    return messages
  }

  private static func assistantContent(
    from snapshot: ProviderPromptMessage,
    supportsHistoricalReasoningPreservation: Bool
  ) -> String {
    guard supportsHistoricalReasoningPreservation,
      let reasoningContent = snapshot.reasoningContent,
      !reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return snapshot.content
    }
    return "<think>\n\(reasoningContent)\n</think>\n\n\(snapshot.content)"
  }

  private static func chatTemplateAdditionalContext(
    reasoningSelection: ReasoningSelection,
    supportsHistoricalReasoningPreservation: Bool
  ) -> [String: any Sendable] {
    var additionalContext: [String: any Sendable] = [
      "enable_thinking": reasoningSelection.isEnabled
    ]
    if supportsHistoricalReasoningPreservation {
      additionalContext["preserve_thinking"] = true
    }
    if let reasoningEffort = reasoningSelection.effort {
      additionalContext["reasoning_effort"] = reasoningEffort.rawValue
    }
    return additionalContext
  }

  private static func mlxToolCall(
    from snapshot: ProviderToolCall
  ) -> MLXLMCommon.ToolCall {
    MLXLMCommon.ToolCall(
      function: MLXLMCommon.ToolCall.Function(
        name: snapshot.name,
        arguments: snapshot.arguments.mapValues(jsonValue(from:))
      ),
      id: snapshot.id
    )
  }

  private static func jsonValue(from value: ToolArgumentValue) -> JSONValue {
    switch value {
    case .string(let string):
      return .string(string)
    case .number(let number):
      if number.rounded() == number,
        number >= Double(Int.min),
        number <= Double(Int.max)
      {
        return .int(Int(number))
      }
      return .double(number)
    case .bool(let bool):
      return .bool(bool)
    case .array(let array):
      return .array(array.map(jsonValue(from:)))
    case .object(let object):
      return .object(object.mapValues(jsonValue(from:)))
    case .null:
      return .null
    }
  }

  private static func validatedChatMessages(
    from snapshots: [ProviderPromptMessage],
    supportsHistoricalReasoningPreservation: Bool
  ) throws -> [Chat.Message] {
    try validatedTemplateMessages(
      chatMessages(
        from: snapshots,
        supportsHistoricalReasoningPreservation:
          supportsHistoricalReasoningPreservation
      ))
  }

}
