import Foundation

@MainActor
struct ChatGenerationCoordinator {
  private let runtime: any ChatModelRuntime
  private let streamingFlushInterval: TimeInterval
  private let streamingFlushCharacterLimit: Int

  init(
    runtime: any ChatModelRuntime,
    streamingFlushInterval: TimeInterval,
    streamingFlushCharacterLimit: Int
  ) {
    self.runtime = runtime
    self.streamingFlushInterval = streamingFlushInterval
    self.streamingFlushCharacterLimit = streamingFlushCharacterLimit
  }

  func streamAssistantReply(
    messages: [ChatMessage],
    systemPrompt: String,
    settings: ChatGenerationSettings,
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
      flushBufferedChunks()
    }

    for try await event in stream {
      try Task.checkCancellation()
      switch event {
      case .chunk(let chunk):
        bufferedChunk += chunk
        if shouldFlushBufferedChunks() {
          flushBufferedChunks()
        }
      case .completed(let metrics):
        flushBufferedChunks()
        updateGenerationMetrics(metrics)
        await updateContextUsage()
      }
    }
  }
}
