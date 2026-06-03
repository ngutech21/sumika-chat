import Foundation

public enum ChatGenerationError: LocalizedError, Equatable, Sendable {
  case streamInterrupted

  public var errorDescription: String? {
    switch self {
    case .streamInterrupted:
      "Model generation ended before completion."
    }
  }
}

@MainActor
public struct ChatGenerationCoordinator {
  private let runtime: any ChatModelRuntime
  private let turnTracer: any TurnTracing
  private let streamingFlushInterval: TimeInterval
  private let streamingFlushCharacterLimit: Int

  public init(
    runtime: any ChatModelRuntime,
    turnTracer: any TurnTracing = NoopTurnTracer(),
    streamingFlushInterval: TimeInterval,
    streamingFlushCharacterLimit: Int
  ) {
    self.runtime = runtime
    self.turnTracer = turnTracer
    self.streamingFlushInterval = streamingFlushInterval
    self.streamingFlushCharacterLimit = streamingFlushCharacterLimit
  }

  public func streamAssistantReply(
    turnID: ChatTurnRecord.ID? = nil,
    interactionMode: WorkspaceInteractionMode? = nil,
    messages: [ChatMessage],
    systemPrompt: String,
    settings: ChatGenerationSettings,
    stopAfterCompleteToolAction: Bool = false,
    appendChunk: (String) -> Void,
    updateGenerationMetrics: (ChatGenerationMetrics?) -> Void,
    updateContextUsage: () async -> Void
  ) async throws {
    let generationID = UUID()
    let metadata = TurnTraceMetadata(
      turnID: turnID,
      generationID: generationID,
      tracer: turnTracer,
      interactionMode: interactionMode
    )

    try await TurnTraceContext.$current.withValue(metadata) {
      try await streamAssistantReplyWithTraceContext(
        turnID: turnID,
        generationID: generationID,
        interactionMode: interactionMode,
        messages: messages,
        systemPrompt: systemPrompt,
        settings: settings,
        stopAfterCompleteToolAction: stopAfterCompleteToolAction,
        appendChunk: appendChunk,
        updateGenerationMetrics: updateGenerationMetrics,
        updateContextUsage: updateContextUsage
      )
    }
  }

  private func streamAssistantReplyWithTraceContext(
    turnID: ChatTurnRecord.ID?,
    generationID: UUID,
    interactionMode: WorkspaceInteractionMode?,
    messages: [ChatMessage],
    systemPrompt: String,
    settings: ChatGenerationSettings,
    stopAfterCompleteToolAction: Bool,
    appendChunk: (String) -> Void,
    updateGenerationMetrics: (ChatGenerationMetrics?) -> Void,
    updateContextUsage: () async -> Void
  ) async throws {
    let generationStartedAt = Date()
    let stream = try await runtime.streamReply(
      for: messages,
      attachments: [],
      systemPrompt: systemPrompt,
      settings: settings
    )

    var bufferedChunk = ""
    var generatedContent = ""
    var displayedPartialToolAction = ""
    var lastFlushDate = Date()
    var didStopAfterCompleteToolAction = false
    var didComplete = false
    let streamConsumptionStartedAt = Date()

    func flushBufferedChunks() {
      guard !bufferedChunk.isEmpty else {
        return
      }
      guard !Task.isCancelled else {
        bufferedChunk = ""
        return
      }

      let startedAt = Date()
      appendChunk(bufferedChunk)
      let durationMs = Date().timeIntervalSince(startedAt) * 1000
      Task {
        await turnTracer.recordTurnTraceEvent(
          TurnTraceEvent(
            turnID: turnID,
            generationID: generationID,
            phase: .uiFlush,
            durationMs: durationMs,
            messageCount: messages.count,
            interactionMode: interactionMode
          )
        )
      }
      bufferedChunk = ""
      lastFlushDate = Date()
    }

    func shouldFlushBufferedChunks() -> Bool {
      bufferedChunk.count >= streamingFlushCharacterLimit
        || Date().timeIntervalSince(lastFlushDate) >= streamingFlushInterval
    }

    defer {
      if !didStopAfterCompleteToolAction {
        flushBufferedChunks()
      }
    }

    generationLoop: for try await event in stream {
      try Task.checkCancellation()
      switch event {
      case .chunk(let chunk):
        generatedContent += chunk
        bufferedChunk += chunk
        if stopAfterCompleteToolAction,
          let action = CompleteToolActionBoundary.firstCompleteAction(from: bufferedChunk)
        {
          let startedAt = Date()
          appendChunk(action)
          displayedPartialToolAction = action
          let durationMs = Date().timeIntervalSince(startedAt) * 1000
          Task {
            await turnTracer.recordTurnTraceEvent(
              TurnTraceEvent(
                turnID: turnID,
                generationID: generationID,
                phase: .uiFlush,
                durationMs: durationMs,
                messageCount: messages.count,
                interactionMode: interactionMode
              )
            )
          }
          bufferedChunk = ""
          didStopAfterCompleteToolAction = true
          break generationLoop
        }
        if shouldFlushBufferedChunks() {
          if !stopAfterCompleteToolAction {
            flushBufferedChunks()
          }
        }
      case .completed(let metrics):
        flushBufferedChunks()
        let completedMetrics = try await generationMetrics(
          from: metrics,
          generatedContent: generatedContent,
          startedAt: generationStartedAt
        )
        updateGenerationMetrics(completedMetrics)
        await updateContextUsage()
        didComplete = true
      }
    }

    if didStopAfterCompleteToolAction && !didComplete {
      let partialDurationMs = Date().timeIntervalSince(generationStartedAt) * 1000
      await turnTracer.recordTurnTraceEvent(
        TurnTraceEvent(
          turnID: turnID,
          generationID: generationID,
          phase: .runtimePartialDecode,
          durationMs: Date().timeIntervalSince(streamConsumptionStartedAt) * 1000,
          messageCount: messages.count,
          interactionMode: interactionMode
        )
      )
      let partialMetrics = try await partialGenerationMetrics(
        generatedContent: displayedPartialToolAction,
        durationMs: partialDurationMs
      )
      updateGenerationMetrics(partialMetrics)
      await updateContextUsage()
    } else if !didComplete {
      throw ChatGenerationError.streamInterrupted
    }
  }

  private func generationMetrics(
    from metrics: ChatGenerationMetrics?,
    generatedContent: String,
    startedAt: Date
  ) async throws -> ChatGenerationMetrics? {
    let durationMs = Date().timeIntervalSince(startedAt) * 1000
    if let metrics {
      return ChatGenerationMetrics(
        generatedTokenCount: metrics.generatedTokenCount,
        tokensPerSecond: metrics.tokensPerSecond,
        durationMs: durationMs
      )
    }

    return try await partialGenerationMetrics(
      generatedContent: generatedContent,
      durationMs: durationMs
    )
  }

  private func partialGenerationMetrics(
    generatedContent: String,
    durationMs: Double
  ) async throws -> ChatGenerationMetrics? {
    guard !generatedContent.isEmpty else {
      return nil
    }

    let generatedTokenCount = try await runtime.generatedTokenCount(for: generatedContent)
    let durationSeconds = max(durationMs / 1000, 0.001)
    return ChatGenerationMetrics(
      generatedTokenCount: generatedTokenCount,
      tokensPerSecond: Double(generatedTokenCount) / durationSeconds,
      durationMs: durationMs
    )
  }
}

private enum CompleteToolActionBoundary {
  static func firstCompleteAction(from text: String) -> String? {
    guard let actionStart = text.range(of: "<action")?.lowerBound else {
      return nil
    }

    guard
      let actionEnd = text.range(
        of: "</action>",
        range: text.index(after: actionStart)..<text.endIndex
      )
    else {
      return nil
    }

    let blockEnd = actionEnd.upperBound
    guard text[blockEnd...].range(of: "<action") == nil else {
      return nil
    }

    return String(text[actionStart..<blockEnd])
  }
}
