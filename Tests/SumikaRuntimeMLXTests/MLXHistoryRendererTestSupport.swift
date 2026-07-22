import MLXLMCommon
import SumikaCore

@testable import SumikaRuntimeMLX

extension MLXHistoryRenderer {
  /// Test-only convenience that builds cache snapshots straight from chat
  /// messages without normalization.
  nonisolated static func messageSnapshot(
    from messages: [Chat.Message]
  ) -> [ProviderPromptMessage] {
    messages.map { message in
      ProviderPromptMessage(role: message.role.rawValue, content: message.content)
    }
  }

  nonisolated static func generationHistorySnapshot(
    from entries: ArraySlice<ProjectedModelContextEntry>
  ) -> [ProviderPromptMessage] {
    ProviderPromptProjection.normalized(
      from: entries,
      dropsTrailingUser: true
    ).messages
  }

  nonisolated static func generationHistoryMessages(
    from entries: ArraySlice<ProjectedModelContextEntry>
  ) throws -> [Chat.Message] {
    try validatedChatMessages(from: generationHistorySnapshot(from: entries))
  }

  nonisolated static func generationHistoryMessages(
    from transcript: ModelPromptProjection
  ) throws -> [Chat.Message] {
    try generationInput(from: transcript).history
  }

  nonisolated static func templateMessages(
    from transcript: ModelPromptProjection,
    attachments: [ChatAttachment],
    systemPrompt: String
  ) throws -> [Chat.Message] {
    _ = attachments
    let history = try validatedChatMessages(
      from: ProviderPromptProjection.normalized(from: transcript).messages
    )
    return try runtimeHistoryMessages(systemPrompt: systemPrompt, history: history)
  }
}
