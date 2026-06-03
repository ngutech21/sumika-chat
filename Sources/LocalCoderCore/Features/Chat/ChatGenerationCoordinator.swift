import Foundation

@MainActor
public struct ChatGenerationCoordinator {
  private let runtime: any ChatModelRuntime
  private let streamingFlushInterval: TimeInterval
  private let streamingFlushCharacterLimit: Int

  public init(
    runtime: any ChatModelRuntime,
    streamingFlushInterval: TimeInterval,
    streamingFlushCharacterLimit: Int
  ) {
    self.runtime = runtime
    self.streamingFlushInterval = streamingFlushInterval
    self.streamingFlushCharacterLimit = streamingFlushCharacterLimit
  }

  public func streamAssistantReply(
    messages: [ChatMessage],
    systemPrompt: String,
    settings: ChatGenerationSettings,
    stopAfterCompleteToolAction: Bool = false,
    appendChunk: (String) -> Void,
    updateGenerationMetrics: (ChatGenerationMetrics?) -> Void,
    updateContextUsage: () async -> Void
  ) async throws {
    let stream = try await runtime.streamReply(
      for: messages,
      attachments: [],
      systemPrompt: systemPrompt,
      settings: settings
    )

    var bufferedChunk = ""
    var lastFlushDate = Date()
    var didStopAfterCompleteToolAction = false
    var didComplete = false

    func flushBufferedChunks() {
      guard !bufferedChunk.isEmpty else {
        return
      }
      guard !Task.isCancelled else {
        bufferedChunk = ""
        return
      }

      appendChunk(bufferedChunk)
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
        bufferedChunk += chunk
        if stopAfterCompleteToolAction,
          let action = CompleteToolActionBoundary.firstCompleteAction(from: bufferedChunk)
        {
          appendChunk(action)
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
        updateGenerationMetrics(metrics)
        await updateContextUsage()
        didComplete = true
      }
    }

    if didStopAfterCompleteToolAction && !didComplete {
      updateGenerationMetrics(nil)
      await updateContextUsage()
    }
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
