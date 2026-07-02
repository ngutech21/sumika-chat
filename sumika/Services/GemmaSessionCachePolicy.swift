import Foundation
import MLXLMCommon
import SumikaCore

nonisolated enum GemmaSessionCachePolicy {
  nonisolated static func cacheIdentity(
    systemPrompt: String,
    settings: ChatGenerationSettings,
    projectionMode: ModelContextProjectionMode
  ) -> GemmaSessionCacheIdentity {
    GemmaSessionCacheIdentity(
      systemPrompt: GemmaHistoryRenderer.normalizedRuntimeSystemPrompt(systemPrompt),
      projectionMode: projectionMode,
      maxKVSize: settings.maxKVSize,
      reasoningEnabled: settings.reasoningEnabled
    )
  }

  nonisolated static func streamMessages(
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

  nonisolated static func runtimeCacheDebugSnapshot(
    from trace: GemmaSessionCacheTrace,
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
      systemPromptChanged: trace.systemPromptChanged,
      currentPromptContextChanged: trace.currentPromptContextChanged
    )
  }

  nonisolated private static func reuseStrategyName(for mode: GemmaSessionCacheMode) -> String {
    switch mode {
    case .newSession, .dirtyRebuild:
      "new_session"
    case .reusedSession:
      "reused_session"
    case .appendDelta:
      "append_delta"
    }
  }

  nonisolated static func trace(
    mode: GemmaSessionCacheMode,
    reason: GemmaSessionCacheReason,
    currentHistory: [GemmaMessageSnapshot],
    currentIdentity: GemmaSessionCacheIdentity,
    cachedPrefix: [GemmaMessageSnapshot]?,
    cachedIdentity: GemmaSessionCacheIdentity?,
    appendOnly: Bool,
    mismatchReason: String?,
    firstMismatchIndex: Int?
  ) -> GemmaSessionCacheTrace {
    let reusedMessageCount = appendOnly ? (cachedPrefix?.count ?? 0) : 0
    let appendedMessageCount =
      appendOnly ? max(0, currentHistory.count - (cachedPrefix?.count ?? 0)) : currentHistory.count
    return GemmaSessionCacheTrace(
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
      systemPromptChanged: cachedIdentity.map { $0.systemPrompt != currentIdentity.systemPrompt },
      currentPromptContextChanged: nil
    )
  }

  nonisolated static func identityMismatchReason(
    cached: GemmaSessionCacheIdentity,
    current: GemmaSessionCacheIdentity
  ) -> GemmaSessionCacheReason {
    if cached.maxKVSize != current.maxKVSize {
      return .maxKVSizeChanged
    }
    if cached.reasoningEnabled != current.reasoningEnabled {
      return .reasoningChanged
    }
    return .identityChanged
  }

  nonisolated static func firstMismatchIndex(
    cachedPrefix: [GemmaMessageSnapshot],
    currentHistory: [GemmaMessageSnapshot]
  ) -> Int? {
    let sharedCount = min(cachedPrefix.count, currentHistory.count)
    for index in 0..<sharedCount where cachedPrefix[index] != currentHistory[index] {
      return index
    }
    return cachedPrefix.count == currentHistory.count ? nil : sharedCount
  }

  nonisolated static func isPrefix(
    _ prefix: [GemmaMessageSnapshot],
    of messages: [GemmaMessageSnapshot]
  ) -> Bool {
    guard prefix.count <= messages.count else {
      return false
    }
    return zip(prefix, messages).allSatisfy(==)
  }

  nonisolated static func contentByteCount(for messages: [Chat.Message]) -> Int {
    messages.reduce(0) { byteCount, message in
      byteCount + message.content.utf8.count + message.images.count
    }
  }

  nonisolated static func contextSignature(
    for messages: [GemmaMessageSnapshot],
    identity: GemmaSessionCacheIdentity
  ) -> String {
    "identity-\(identitySignature(for: identity)):history-\(contextSignature(for: messages))"
  }

  nonisolated private static func identitySignature(
    for identity: GemmaSessionCacheIdentity
  ) -> String {
    hashSignature { updateString in
      updateString("mlx_owned_cache_identity_v1")
      updateString(identity.systemPrompt ?? "system:nil")
      updateString(identity.projectionMode.signatureComponent)
      updateString(identity.maxKVSize.map(String.init) ?? "max_kv:nil")
      updateString(identity.reasoningEnabled ? "reasoning:on" : "reasoning:off")
    }
  }

  nonisolated static func contextSignature(for messages: [GemmaMessageSnapshot]) -> String {
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
          for byte in (toolCall.id ?? "nil").utf8 {
            update(byte)
          }
          update(0)
          for byte in toolCall.name.utf8 {
            update(byte)
          }
          update(0)
          for byte in toolArgumentSignature(from: .object(toolCall.arguments)).utf8 {
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

  nonisolated private static func toolArgumentSignature(from value: ToolArgumentValue) -> String {
    switch value {
    case .string(let string):
      return "string:\(string)"
    case .number(let number):
      return "number:\(number)"
    case .bool(let bool):
      return "bool:\(bool)"
    case .array(let array):
      return "array:[\(array.map(toolArgumentSignature(from:)).joined(separator: ","))]"
    case .object(let object):
      let entries = object.keys.sorted().map { key in
        "\(key):\(toolArgumentSignature(from: object[key] ?? .null))"
      }
      return "object:{\(entries.joined(separator: ","))}"
    case .null:
      return "null"
    }
  }

  nonisolated private static func hashSignature(_ body: ((String) -> Void) -> Void) -> String {
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
