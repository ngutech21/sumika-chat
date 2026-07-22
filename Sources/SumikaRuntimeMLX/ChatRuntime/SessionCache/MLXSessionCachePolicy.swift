import Foundation
import MLXLMCommon
import SumikaCore

enum MLXSessionCachePolicy {
  static func cacheIdentity(
    systemPrompt: String,
    settings: ChatGenerationSettings,
    projectionMode: ModelContextProjectionMode
  ) -> MLXSessionCacheIdentity {
    MLXSessionCacheIdentity(
      systemPrompt: MLXHistoryRenderer.normalizedRuntimeSystemPrompt(systemPrompt),
      projectionMode: projectionMode,
      maxKVSize: settings.maxKVSize,
      reasoningEnabled: settings.reasoningEnabled
    )
  }

  static func streamMessages(
    history: [Chat.Message],
    promptMessages: [Chat.Message],
    appendDeltaStartIndex: Int?
  ) -> [Chat.Message] {
    guard let appendDeltaStartIndex else {
      return promptMessages
    }
    let boundedStartIndex = min(max(0, appendDeltaStartIndex), history.count)
    return Array(history[boundedStartIndex...]) + promptMessages
  }

  static func chatSessionInstructions(
    for mode: MLXSessionCacheMode,
    systemPrompt: String
  ) -> String? {
    switch mode {
    case .newSession, .dirtyRebuild:
      MLXHistoryRenderer.normalizedRuntimeSystemPrompt(systemPrompt)
    case .reusedSession, .appendDelta:
      nil
    }
  }

  static func runtimeCacheDebugSnapshot(
    from trace: MLXSessionCacheTrace,
    appendDeltaStartIndex: Int?,
    generationID: UUID,
    recordedAt: Date = Date()
  ) -> RuntimeCacheDebugSnapshot {
    RuntimeCacheDebugSnapshot(
      generationID: generationID,
      recordedAt: recordedAt,
      cacheMode: trace.cacheMode.rawValue,
      cacheReason: trace.cacheReason.rawValue,
      reuseStrategy: reuseStrategyName(for: trace.cacheMode),
      appendDeltaStartIndex: appendDeltaStartIndex,
      contextSignature: trace.contextSignature,
      previousContextSignature: trace.previousContextSignature,
      appendOnly: trace.appendOnly,
      reusedMessageCount: trace.reusedMessageCount,
      appendedMessageCount: trace.appendedMessageCount,
      mismatchReason: trace.mismatchReason,
      firstMismatchIndex: trace.firstMismatchIndex,
      systemPromptChanged: trace.systemPromptChanged
    )
  }

  private static func reuseStrategyName(for mode: MLXSessionCacheMode) -> String {
    switch mode {
    case .newSession, .dirtyRebuild:
      "new_session"
    case .reusedSession:
      "reused_session"
    case .appendDelta:
      "append_delta"
    }
  }

  static func trace(
    mode: MLXSessionCacheMode,
    reason: MLXSessionCacheReason,
    currentHistory: [ProviderPromptMessage],
    currentIdentity: MLXSessionCacheIdentity,
    cachedPrefix: [ProviderPromptMessage]?,
    cachedIdentity: MLXSessionCacheIdentity?,
    appendOnly: Bool,
    mismatchReason: String?,
    firstMismatchIndex: Int?
  ) -> MLXSessionCacheTrace {
    let reusedMessageCount = appendOnly ? (cachedPrefix?.count ?? 0) : 0
    let appendedMessageCount =
      appendOnly ? max(0, currentHistory.count - (cachedPrefix?.count ?? 0)) : currentHistory.count
    return MLXSessionCacheTrace(
      cacheMode: mode,
      cacheReason: reason,
      contextSignature: contextSignature(for: currentHistory, identity: currentIdentity),
      previousContextSignature: cachedPrefix.flatMap { prefix in
        cachedIdentity.map { identity in
          contextSignature(for: prefix, identity: identity)
        }
      },
      appendOnly: appendOnly,
      reusedMessageCount: reusedMessageCount,
      appendedMessageCount: appendedMessageCount,
      mismatchReason: mismatchReason,
      firstMismatchIndex: firstMismatchIndex,
      systemPromptChanged: cachedIdentity.map { $0.systemPrompt != currentIdentity.systemPrompt }
    )
  }

  static func identityMismatchReason(
    cached: MLXSessionCacheIdentity,
    current: MLXSessionCacheIdentity
  ) -> MLXSessionCacheReason {
    if cached.maxKVSize != current.maxKVSize {
      return .maxKVSizeChanged
    }
    if cached.reasoningEnabled != current.reasoningEnabled {
      return .reasoningChanged
    }
    return .identityChanged
  }

  static func firstMismatchIndex(
    cachedPrefix: [ProviderPromptMessage],
    currentHistory: [ProviderPromptMessage]
  ) -> Int? {
    let sharedCount = min(cachedPrefix.count, currentHistory.count)
    for index in 0..<sharedCount where cachedPrefix[index] != currentHistory[index] {
      return index
    }
    return cachedPrefix.count == currentHistory.count ? nil : sharedCount
  }

  static func isPrefix(
    _ prefix: [ProviderPromptMessage],
    of messages: [ProviderPromptMessage]
  ) -> Bool {
    guard prefix.count <= messages.count else {
      return false
    }
    return zip(prefix, messages).allSatisfy(==)
  }

  /// Whether an append-only delta (the messages appended after `cachedPrefixCount`)
  /// begins with a tool-response message. Such a delta must not reuse the cached
  /// session: rendering a lone tool response through the chat template drops it,
  /// because its paired assistant tool_call lives in the cached prefix, not in the
  /// delta. The caller forces a full rebuild in that case so call and result are
  /// templated adjacently.
  static func deltaBeginsWithToolResult(
    cachedPrefixCount: Int,
    historySnapshot: [ProviderPromptMessage],
    promptFirstRole: String?
  ) -> Bool {
    let toolRole = Chat.Message.Role.tool.rawValue
    if cachedPrefixCount >= historySnapshot.count {
      return promptFirstRole == toolRole
    }
    return historySnapshot[cachedPrefixCount].role == toolRole
  }

  static func contentByteCount(for messages: [Chat.Message]) -> Int {
    messages.reduce(0) { byteCount, message in
      byteCount + message.content.utf8.count + message.images.count
    }
  }

  static func contextSignature(
    for messages: [ProviderPromptMessage],
    identity: MLXSessionCacheIdentity
  ) -> String {
    "identity-\(identitySignature(for: identity)):history-\(contextSignature(for: messages))"
  }

  private static func identitySignature(
    for identity: MLXSessionCacheIdentity
  ) -> String {
    hashSignature { updateString in
      updateString("mlx_owned_cache_identity_v1")
      updateString(identity.systemPrompt ?? "system:nil")
      updateString(identity.projectionMode.signatureComponent)
      updateString(identity.maxKVSize.map(String.init) ?? "max_kv:nil")
      updateString(identity.reasoningEnabled ? "reasoning:on" : "reasoning:off")
    }
  }

  static func contextSignature(for messages: [ProviderPromptMessage]) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    func update(_ byte: UInt8) {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }

    for message in messages {
      for byte in message.role.utf8 {
        update(byte)
      }
      update(0)
      for byte in message.content.utf8 {
        update(byte)
      }
      if !message.toolCalls.isEmpty {
        update(0xFD)
        for toolCall in message.toolCalls {
          for byte in toolCall.canonicalPayloadJSON.utf8 {
            update(byte)
          }
          update(0)
        }
      }
      if let toolCallID = message.toolCallID {
        update(0xFC)
        for byte in toolCallID.utf8 {
          update(byte)
        }
      }
      for signature in message.imageSignatures {
        update(0xFE)
        for byte in signature.utf8 {
          update(byte)
        }
      }
      update(0xFF)
    }

    return String(format: "%016llx", hash)
  }

  private static func hashSignature(_ body: ((String) -> Void) -> Void) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    func update(_ byte: UInt8) {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }

    body { value in
      for byte in value.utf8 {
        update(byte)
      }
      update(0)
    }

    return String(format: "%016llx", hash)
  }
}
