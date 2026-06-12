import Foundation
import LocalCoderCore
import MLXLMCommon

nonisolated enum GemmaHistoryRenderer {
  /// Full history keeps the rendered transcript append-only so the cached
  /// KV prefix stays a byte-stable prefix of every later generation. Receipt
  /// compaction rewrites past observations and would invalidate the cache
  /// after every tool turn.
  nonisolated static let runtimeProjectionMode = ModelContextProjectionMode.fullHistory

  nonisolated static func messageSnapshot(from messages: [Chat.Message]) -> [GemmaMessageSnapshot] {
    messages.map { message in
      GemmaMessageSnapshot(role: message.role.rawValue, content: message.content)
    }
  }

  nonisolated static func chatMessage(
    from entry: ProjectedModelContextEntry,
    images: [UserInput.Image] = []
  ) -> Chat.Message {
    switch entry.role {
    case .user:
      return .user(entry.content, images: images)
    case .assistant:
      return .assistant(entry.content)
    }
  }

  nonisolated static func imageInputs(
    from attachments: [ChatAttachment],
    attachmentStore: ChatAttachmentStore = ChatAttachmentStore()
  ) throws -> [UserInput.Image] {
    try attachments.map { attachment in
      .url(try attachmentStore.validateStoredFile(for: attachment))
    }
  }

  nonisolated static func imageTypes(from attachments: [ChatAttachment]) -> [String]? {
    let types = attachments.compactMap(\.mimeType)
    return types.isEmpty ? nil : types
  }

  nonisolated static func imageByteCount(from attachments: [ChatAttachment]) -> Int? {
    let byteCount = attachments.reduce(0) { total, attachment in
      total + attachment.byteSize
    }
    return byteCount == 0 ? nil : byteCount
  }

  nonisolated static func templateMessages(
    from transcript: ModelContextSnapshot,
    attachments: [ChatAttachment],
    systemPrompt: String
  ) throws -> [Chat.Message] {
    _ = attachments
    return try validatedTemplateMessages(
      runtimeHistoryMessages(
        systemPrompt: systemPrompt,
        history: normalizedChatMessages(
          transcript.projectedEntries(mode: runtimeProjectionMode)
            .map { Self.chatMessage(from: $0) }
        )
      ),
      allowsSystemPrompt: true
    )
  }

  nonisolated static func runtimeHistoryMessages(
    systemPrompt: String,
    history: [Chat.Message]
  ) throws -> [Chat.Message] {
    let normalizedSystemPrompt = normalizedRuntimeSystemPrompt(systemPrompt)
    let messages =
      if let normalizedSystemPrompt {
        [Chat.Message.system(normalizedSystemPrompt)] + history
      } else {
        history
      }
    return try validatedTemplateMessages(messages, allowsSystemPrompt: true)
  }

  nonisolated static func normalizedRuntimeSystemPrompt(_ systemPrompt: String) -> String? {
    ModelFacingPromptRenderer.normalizedSystemPrompt(systemPrompt)
  }

  nonisolated static func normalizedChatMessages(_ messages: [Chat.Message]) -> [Chat.Message] {
    messages.reduce(into: []) { normalizedMessages, message in
      guard !message.content.isEmpty else {
        return
      }

      guard let lastMessage = normalizedMessages.last, lastMessage.role == message.role else {
        normalizedMessages.append(message)
        return
      }

      let mergedContent = [lastMessage.content, message.content].joined(separator: "\n\n")
      normalizedMessages[normalizedMessages.index(before: normalizedMessages.endIndex)] =
        Chat.Message(role: lastMessage.role, content: mergedContent)
    }
  }

  nonisolated static func validatedTemplateMessages(
    _ messages: [Chat.Message],
    allowsSystemPrompt: Bool = false
  ) throws -> [Chat.Message] {
    let bodyMessages: ArraySlice<Chat.Message>
    if messages.first?.role == .system {
      guard allowsSystemPrompt else {
        throw GemmaMLXRuntimeError.invalidChatTemplateMessageSequence
      }
      bodyMessages = messages.dropFirst()
    } else {
      bodyMessages = messages[...]
    }

    guard bodyMessages.allSatisfy({ $0.role == .user || $0.role == .assistant }) else {
      throw GemmaMLXRuntimeError.invalidChatTemplateMessageSequence
    }

    for index in bodyMessages.indices.dropFirst() {
      let previousIndex = bodyMessages.index(before: index)
      if bodyMessages[previousIndex].role == bodyMessages[index].role {
        throw GemmaMLXRuntimeError.invalidChatTemplateMessageSequence
      }
    }

    return messages
  }

  /// Mirrors `normalizedChatMessages` (skip empty, merge consecutive same-role
  /// with a blank line) while carrying image signatures, then drops trailing
  /// user messages. Single source for both the template history and the cache
  /// prefix snapshot so the two can never drift.
  nonisolated private static func normalizedHistoryItems(
    from entries: ArraySlice<ProjectedModelContextEntry>
  ) -> [GemmaHistoryItem] {
    var items: [GemmaHistoryItem] = []
    for entry in entries {
      guard !entry.content.isEmpty else {
        continue
      }
      let role: Chat.Message.Role = entry.role == .user ? .user : .assistant
      if let last = items.last, last.role == role {
        items[items.count - 1] = GemmaHistoryItem(
          role: role,
          content: [last.content, entry.content].joined(separator: "\n\n"),
          imageSignatures: last.imageSignatures + entry.imageSignatures
        )
      } else {
        items.append(
          GemmaHistoryItem(
            role: role,
            content: entry.content,
            imageSignatures: entry.imageSignatures
          )
        )
      }
    }

    while items.last?.role == .user {
      items.removeLast()
    }

    return items
  }

  nonisolated static func generationHistoryMessages(
    from entries: ArraySlice<ProjectedModelContextEntry>
  ) throws -> [Chat.Message] {
    try validatedTemplateMessages(
      normalizedHistoryItems(from: entries).map {
        Chat.Message(role: $0.role, content: $0.content)
      }
    )
  }

  nonisolated static func generationHistorySnapshot(
    from entries: ArraySlice<ProjectedModelContextEntry>
  ) -> [GemmaMessageSnapshot] {
    normalizedHistoryItems(from: entries).map { item in
      GemmaMessageSnapshot(
        role: item.role.rawValue,
        content: item.content,
        imageSignatures: item.imageSignatures
      )
    }
  }

  nonisolated static func generationHistoryMessages(
    from transcript: ModelContextSnapshot
  ) throws -> [Chat.Message] {
    let entries = transcript.projectedEntries(mode: runtimeProjectionMode)
    guard let lastUserIndex = entries.lastIndex(where: { $0.role == .user }) else {
      return []
    }
    return try generationHistoryMessages(from: entries[..<lastUserIndex])
  }
}
