import Foundation
import LocalCoderCore
import MLXLMCommon

nonisolated enum GemmaSessionCachePolicy {
  nonisolated static let gemmaRendererVersion = 1

  nonisolated static func streamInput(
    for reuseStrategy: GemmaSessionReuseStrategy,
    history: [Chat.Message],
    promptMessage: Chat.Message
  ) -> GemmaSessionStreamInput {
    switch reuseStrategy {
    case .none, .exactPrompt:
      return .prompt(promptMessage.content, images: promptMessage.images)
    case .appendHistoryDelta(let startIndex):
      let boundedStartIndex = min(max(0, startIndex), history.count)
      return .messages(Array(history[boundedStartIndex...]) + [promptMessage])
    }
  }

  nonisolated static func cacheDecision(
    cachedPrefix: [GemmaMessageSnapshot]?,
    cachedSettings: ChatGenerationSettings?,
    cachedContextSignature: GemmaRenderedContextSignature? = nil,
    cachedState: GemmaCachedSessionState?,
    currentHistory: [GemmaMessageSnapshot],
    currentSettings: ChatGenerationSettings,
    projectionMode: ModelContextProjectionMode = .fullHistory,
    currentSystemPrompt: String? = nil,
    currentNativeToolSchemaHash: String = nativeToolSchemaSignature(from: nil),
    currentRendererVersion: Int = gemmaRendererVersion
  ) -> GemmaSessionCacheDecision {
    let currentSignature = renderedContextSignature(
      for: currentHistory,
      settings: currentSettings,
      projectionMode: projectionMode,
      systemPrompt: currentSystemPrompt,
      nativeToolSchemaHash: currentNativeToolSchemaHash,
      rendererVersion: currentRendererVersion
    )
    let previousSignature =
      cachedContextSignature
      ?? cachedPrefix.flatMap { prefix in
        cachedSettings.map { settings in
          renderedContextSignature(
            for: prefix,
            settings: settings,
            projectionMode: projectionMode
          )
        }
      }
    let appendOnly = cachedPrefix.map { isPrefix($0, of: currentHistory) } ?? false
    let reusedMessageCount = appendOnly ? (cachedPrefix?.count ?? 0) : 0
    let appendedMessageCount =
      appendOnly ? max(0, currentHistory.count - (cachedPrefix?.count ?? 0)) : currentHistory.count
    let mismatchIndex: Int?
    let systemPromptChanged: Bool?
    let currentPromptContextChanged: Bool?
    if let cachedPrefix {
      mismatchIndex = firstMismatchIndex(cachedPrefix: cachedPrefix, currentHistory: currentHistory)
      let renderedHistorySystemPromptChanged =
        baseSystemInstructionBlock(from: cachedPrefix)
        != baseSystemInstructionBlock(from: currentHistory)
      let runtimeSystemPromptChanged =
        previousSignature.map { $0.systemPromptHash != currentSignature.systemPromptHash }
      systemPromptChanged =
        renderedHistorySystemPromptChanged || runtimeSystemPromptChanged == true
      currentPromptContextChanged =
        currentPromptContextBlock(from: cachedPrefix)
        != currentPromptContextBlock(from: currentHistory)
    } else {
      mismatchIndex = nil
      systemPromptChanged = nil
      currentPromptContextChanged = nil
    }

    let cacheMode: GemmaSessionCacheMode
    let cacheReason: GemmaSessionCacheReason
    let reuseStrategy: GemmaSessionReuseStrategy
    let mismatchReason: String?
    if cachedPrefix == nil, let invalidationReason = cachedState?.invalidationReason {
      cacheMode = invalidationReason.cacheMode
      cacheReason = .generationInvalidationReason(from: invalidationReason)
      reuseStrategy = .none
      mismatchReason = nil
    } else if cachedPrefix == nil {
      cacheMode = .newSessionHistory
      cacheReason = .newSessionNoCache
      reuseStrategy = .none
      mismatchReason = nil
    } else if cachedState?.isReusable != true {
      let invalidationReason = cachedState?.invalidationReason ?? .interrupted
      cacheMode = invalidationReason.cacheMode
      cacheReason = .generationInvalidationReason(from: invalidationReason)
      reuseStrategy = .none
      mismatchReason = nil
    } else if Self.cacheAffectingSettingsChanged(cachedSettings, currentSettings) {
      cacheMode = .invalidatedSignatureMismatch
      cacheReason = .invalidatedSettingsChanged
      reuseStrategy = .none
      mismatchReason = "settings_changed"
    } else if cachedPrefix == currentHistory {
      if previousSignature?.hasSamePrefill(as: currentSignature) == true {
        cacheMode = .sessionReused
        if cachedState == .cleanNativeToolCallBoundary {
          cacheReason = .appendOnlyDeltaReused
          reuseStrategy = .appendHistoryDelta(startIndex: cachedPrefix?.count ?? 0)
        } else {
          cacheReason = .sessionReused
          reuseStrategy = .exactPrompt
        }
        mismatchReason = nil
      } else {
        cacheMode = .invalidatedSignatureMismatch
        cacheReason = Self.signatureMismatchReason(
          previousSignature: previousSignature,
          currentSignature: currentSignature
        )
        reuseStrategy = .none
        mismatchReason = "rendered_context_signature_changed"
      }
    } else if appendOnly {
      if Self.canReuseAppendOnlyDelta(
        previousSignature: previousSignature,
        currentSignature: currentSignature
      ) {
        cacheMode = .sessionReused
        cacheReason = .appendOnlyDeltaReused
        reuseStrategy = .appendHistoryDelta(startIndex: cachedPrefix?.count ?? 0)
        mismatchReason = nil
      } else {
        cacheMode = .invalidatedSignatureMismatch
        cacheReason = Self.signatureMismatchReason(
          previousSignature: previousSignature,
          currentSignature: currentSignature
        )
        reuseStrategy = .none
        mismatchReason = "rendered_context_signature_changed"
      }
    } else {
      cacheMode = .invalidatedSignatureMismatch
      cacheReason = Self.historyMismatchReason(
        systemPromptChanged: systemPromptChanged,
        currentPromptContextChanged: currentPromptContextChanged
      )
      reuseStrategy = .none
      mismatchReason = "history_prefix_mismatch"
    }

    return GemmaSessionCacheDecision(
      reuseStrategy: reuseStrategy,
      trace: GemmaSessionCacheTrace(
        cacheMode: cacheMode,
        cacheReason: cacheReason,
        contextSignature: currentSignature.traceValue,
        previousContextSignature: previousSignature?.traceValue,
        appendOnly: appendOnly,
        reusedMessageCount: reusedMessageCount,
        appendedMessageCount: appendedMessageCount,
        mismatchReason: mismatchReason,
        firstMismatchIndex: mismatchReason == nil ? nil : mismatchIndex,
        systemPromptChanged: mismatchReason == nil ? nil : systemPromptChanged,
        currentPromptContextChanged: mismatchReason == nil ? nil : currentPromptContextChanged
      )
    )
  }

  nonisolated static func runtimeCacheDebugSnapshot(
    from trace: GemmaSessionCacheTrace,
    reuseStrategy: GemmaSessionReuseStrategy,
    generationID: UUID,
    recordedAt: Date = Date()
  ) -> RuntimeCacheDebugSnapshot {
    let strategy = runtimeCacheDebugReuseStrategy(reuseStrategy)
    return RuntimeCacheDebugSnapshot(
      generationID: generationID,
      recordedAt: recordedAt,
      cacheMode: trace.cacheMode.rawValue,
      cacheReason: trace.cacheReason.rawValue,
      reuseStrategy: strategy.name,
      appendDeltaStartIndex: strategy.appendDeltaStartIndex,
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

  nonisolated private static func runtimeCacheDebugReuseStrategy(
    _ reuseStrategy: GemmaSessionReuseStrategy
  ) -> (name: String, appendDeltaStartIndex: Int?) {
    switch reuseStrategy {
    case .none:
      ("none", nil)
    case .exactPrompt:
      ("exact_prompt", nil)
    case .appendHistoryDelta(let startIndex):
      ("append_history_delta", startIndex)
    }
  }

  nonisolated static func renderedContextSignature(
    for messages: [GemmaMessageSnapshot],
    settings: ChatGenerationSettings,
    projectionMode: ModelContextProjectionMode = .fullHistory,
    systemPrompt: String? = nil,
    systemPromptHash: String? = nil,
    nativeToolSchemaHash: String = nativeToolSchemaSignature(from: nil),
    rendererVersion: Int = gemmaRendererVersion
  ) -> GemmaRenderedContextSignature {
    GemmaRenderedContextSignature(
      rendererVersion: rendererVersion,
      projectionMode: projectionMode,
      systemPromptHash: systemPromptHash ?? runtimeSystemPromptSignature(from: systemPrompt),
      renderedHistoryHash: contextSignature(for: messages),
      generationSettingsHash: generationSettingsSignature(for: settings),
      nativeToolSchemaHash: nativeToolSchemaHash
    )
  }

  nonisolated private static func signatureMismatchReason(
    previousSignature: GemmaRenderedContextSignature?,
    currentSignature: GemmaRenderedContextSignature
  ) -> GemmaSessionCacheReason {
    guard let previousSignature else {
      return .invalidatedRenderedContextChanged
    }
    if previousSignature.rendererVersion != currentSignature.rendererVersion {
      return .invalidatedRendererVersionChanged
    }
    if previousSignature.projectionMode != currentSignature.projectionMode {
      return .invalidatedRenderedContextChanged
    }
    if previousSignature.systemPromptHash != currentSignature.systemPromptHash {
      return .invalidatedSystemPromptChanged
    }
    return .invalidatedRenderedContextChanged
  }

  nonisolated private static func canReuseAppendOnlyDelta(
    previousSignature: GemmaRenderedContextSignature?,
    currentSignature: GemmaRenderedContextSignature
  ) -> Bool {
    guard let previousSignature else {
      return false
    }
    // Append-only deltas legitimately extend the history, so renderedHistoryHash
    // differs by design and is not compared. nativeToolSchemaHash is excluded for
    // the same reason as in `hasSamePrefill`: it is decode-time only for Gemma.
    return previousSignature.rendererVersion == currentSignature.rendererVersion
      && previousSignature.projectionMode == currentSignature.projectionMode
      && previousSignature.systemPromptHash == currentSignature.systemPromptHash
      && previousSignature.generationSettingsHash == currentSignature.generationSettingsHash
  }

  nonisolated private static func historyMismatchReason(
    systemPromptChanged: Bool?,
    currentPromptContextChanged: Bool?
  ) -> GemmaSessionCacheReason {
    if currentPromptContextChanged == true {
      return .invalidatedCurrentPromptContextBoundary
    }
    if systemPromptChanged == true {
      return .invalidatedToolPromptChanged
    }
    return .invalidatedHistoryPrefixMismatch
  }

  /// Whether a settings change should invalidate a reusable KV-cache prefix.
  ///
  /// Only `maxKVSize` affects the cached prefill. Sampling params and `maxTokens`
  /// are applied at decode time, so changing them keeps the prefix valid (the new
  /// values are pushed onto the reused session instead — see `prepareSession`).
  nonisolated private static func cacheAffectingSettingsChanged(
    _ cached: ChatGenerationSettings?,
    _ current: ChatGenerationSettings
  ) -> Bool {
    guard let cached else { return true }
    return cached.maxKVSize != current.maxKVSize
  }

  nonisolated private static func generationSettingsSignature(
    for settings: ChatGenerationSettings
  ) -> String {
    // Only settings that change the KV-cache prefill belong in the cache signature.
    // Sampling params (temperature/topP/topK) and maxTokens are applied at decode
    // time and never alter the cached prefix, so they must not invalidate it. Only
    // maxKVSize matters here, because it controls cache rotation/eviction.
    hashSignature { updateString in
      updateString(settings.maxKVSize.map(String.init) ?? "nil")
    }
  }

  nonisolated private static func runtimeSystemPromptSignature(from systemPrompt: String?) -> String
  {
    guard
      let normalizedSystemPrompt = GemmaHistoryRenderer.normalizedRuntimeSystemPrompt(
        systemPrompt ?? "")
    else {
      return "none"
    }
    return hashSignature { updateString in
      updateString("runtime_system_prompt_v1")
      updateString(normalizedSystemPrompt)
    }
  }

  nonisolated static func nativeToolSchemaSignature(
    from toolContext: ChatRuntimeToolContext?
  ) -> String {
    guard toolContext?.strategy == .nativeGemma4 else {
      return "none"
    }
    return nativeToolSchemaSignature(for: toolContext?.registry.tools ?? [])
  }

  nonisolated static func nativeToolSchemaSignature(
    for tools: [ToolDefinition]
  ) -> String {
    guard !tools.isEmpty else {
      return "none"
    }

    return hashSignature { updateString in
      updateString("native_gemma4_tools_v1")
      for tool in tools {
        updateString("tool")
        updateString(tool.name.rawValue)
        updateString(tool.description)
        for parameter in tool.parameters {
          updateString("parameter")
          updateString(parameter.name)
          updateString(parameter.description)
          updateString(parameter.isRequired ? "required" : "optional")
          updateString(parameter.valueType.rawValue)
          if let enumValues = parameter.enumValues {
            updateString("enum")
            for value in enumValues {
              updateString(value)
            }
          } else {
            updateString("enum:nil")
          }
          updateString(parameter.defaultValue.map(toolArgumentSignature(from:)) ?? "default:nil")
          updateString(parameter.minimum.map { String($0) } ?? "minimum:nil")
          updateString(parameter.maximum.map { String($0) } ?? "maximum:nil")
        }
      }
    }
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

  nonisolated private static func firstMismatchIndex(
    cachedPrefix: [GemmaMessageSnapshot],
    currentHistory: [GemmaMessageSnapshot]
  ) -> Int? {
    let sharedCount = min(cachedPrefix.count, currentHistory.count)
    for index in 0..<sharedCount where cachedPrefix[index] != currentHistory[index] {
      return index
    }
    return cachedPrefix.count == currentHistory.count ? nil : sharedCount
  }

  nonisolated private static func baseSystemInstructionBlock(
    from messages: [GemmaMessageSnapshot]
  ) -> String? {
    if let first = messages.first, first.role == Chat.Message.Role.system.rawValue {
      return first.content
    }

    guard let block = userSystemInstructionBlock(from: messages) else {
      return nil
    }
    guard let boundary = currentPromptContextBoundary(in: block) else {
      return block
    }
    return String(block[..<boundary.range.lowerBound])
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  nonisolated private static func currentPromptContextBlock(
    from messages: [GemmaMessageSnapshot]
  ) -> CurrentPromptContextRuntimeBlock? {
    guard let block = userSystemInstructionBlock(from: messages),
      let boundary = currentPromptContextBoundary(in: block)
    else {
      return nil
    }
    return CurrentPromptContextRuntimeBlock(
      boundary: boundary.boundary,
      content: String(block[boundary.range.lowerBound...])
    )
  }

  nonisolated private static func userSystemInstructionBlock(
    from messages: [GemmaMessageSnapshot]
  ) -> String? {
    guard let firstUser = messages.first(where: { $0.role == Chat.Message.Role.user.rawValue }),
      firstUser.content.hasPrefix("System instructions:")
    else {
      return nil
    }
    guard let userRequestRange = firstUser.content.range(of: "\n\nUser request:") else {
      return firstUser.content
    }
    return String(firstUser.content[..<userRequestRange.lowerBound])
  }

  nonisolated private static func currentPromptContextBoundary(
    in systemInstructionBlock: String
  ) -> CurrentPromptContextRuntimeBoundaryMatch? {
    CurrentPromptContextRuntimeBoundary.all.compactMap { boundary in
      systemInstructionBlock.range(of: boundary.marker).map { range in
        CurrentPromptContextRuntimeBoundaryMatch(boundary: boundary, range: range)
      }
    }
    .min { $0.range.lowerBound < $1.range.lowerBound }
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

  nonisolated private static func isPrefix(
    _ prefix: [GemmaMessageSnapshot],
    of messages: [GemmaMessageSnapshot]
  ) -> Bool {
    guard prefix.count <= messages.count else {
      return false
    }

    return zip(prefix, messages).allSatisfy(==)
  }

}
