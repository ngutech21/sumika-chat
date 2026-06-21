import Foundation

@testable import SumikaCore

actor NonCooperativeStreamingRuntime: ChatModelRuntime {
  private let chunks: [String]
  private var streamContinuation: CheckedContinuation<Void, Never>?
  private var didReleaseChunks = false
  private(set) var didStartStreaming = false
  private(set) var didFinishStreaming = false

  init(chunks: [String]) {
    self.chunks = chunks
  }

  func load(configuration: ChatModelConfiguration) async throws {}
  func unload() async {}
  func clearContext() async {}

  func releaseChunks() {
    didReleaseChunks = true
    if let streamContinuation {
      streamContinuation.resume()
      self.streamContinuation = nil
    }
  }

  func contextUsage(
    for transcript: ModelContextSnapshot,
    attachments: [ChatAttachment],
    systemPrompt: String
  ) async throws -> ChatContextUsage {
    _ = transcript
    _ = attachments
    _ = systemPrompt
    return ChatContextUsage(usedTokens: 0, tokenLimit: nil)
  }

  func streamReply(
    for transcript: ModelContextSnapshot,
    attachments: [ChatAttachment],
    systemPrompt: String,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = transcript
    _ = attachments
    _ = systemPrompt
    _ = settings

    didStartStreaming = true
    return AsyncThrowingStream { continuation in
      Task.detached { [chunks] in
        await withCheckedContinuation { release in
          Task {
            await self.storeStreamContinuation(release)
          }
        }

        for chunk in chunks {
          continuation.yield(.chunk(chunk))
        }
        continuation.yield(.completed(nil))
        continuation.finish()
        await self.recordStreamFinished()
      }
    }
  }

  private func storeStreamContinuation(_ continuation: CheckedContinuation<Void, Never>) {
    if didReleaseChunks {
      continuation.resume()
      return
    }
    streamContinuation = continuation
    Task {
      try? await Task.sleep(for: .seconds(2))
      self.releaseChunks()
    }
  }

  private func recordStreamFinished() {
    didFinishStreaming = true
  }
}

actor ControlledContextUsageRuntime: ChatModelRuntime {
  private struct PendingContextUsage {
    let id: UUID
    let continuation: CheckedContinuation<ChatContextUsage, Never>
  }

  private var contextUsageContinuations: [PendingContextUsage] = []
  private(set) var completedContextUsageCount = 0

  var contextUsageRequestCount: Int {
    contextUsageContinuations.count
  }

  func load(configuration: ChatModelConfiguration) async throws {
    _ = configuration
  }

  func unload() async {}
  func clearContext() async {}

  func contextUsage(
    for transcript: ModelContextSnapshot,
    attachments: [ChatAttachment],
    systemPrompt: String
  ) async throws -> ChatContextUsage {
    _ = transcript
    _ = attachments
    _ = systemPrompt
    let id = UUID()
    let usage = await withCheckedContinuation { continuation in
      contextUsageContinuations.append(PendingContextUsage(id: id, continuation: continuation))
      Task {
        try? await Task.sleep(for: .seconds(2))
        self.resolveContextUsage(
          id: id,
          with: ChatContextUsage(usedTokens: 0, tokenLimit: nil)
        )
      }
    }
    completedContextUsageCount += 1
    return usage
  }

  private func resolveContextUsage(id: UUID, with usage: ChatContextUsage) {
    guard
      let index = contextUsageContinuations.firstIndex(where: { $0.id == id })
    else {
      return
    }
    let pendingUsage = contextUsageContinuations.remove(at: index)
    pendingUsage.continuation.resume(returning: usage)
  }

  func streamReply(
    for transcript: ModelContextSnapshot,
    attachments: [ChatAttachment],
    systemPrompt: String,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = transcript
    _ = attachments
    _ = systemPrompt
    _ = settings
    return AsyncThrowingStream { continuation in
      continuation.finish()
    }
  }
}

actor CountingClearContextRuntime: ChatModelRuntime {
  private(set) var clearContextCount = 0

  func load(configuration: ChatModelConfiguration) async throws {
    _ = configuration
  }

  func unload() async {}

  func clearContext() async {
    clearContextCount += 1
  }

  func contextUsage(
    for transcript: ModelContextSnapshot,
    attachments: [ChatAttachment],
    systemPrompt: String
  ) async throws -> ChatContextUsage {
    _ = transcript
    _ = attachments
    _ = systemPrompt
    return ChatContextUsage(usedTokens: 0, tokenLimit: nil)
  }

  func streamReply(
    for transcript: ModelContextSnapshot,
    attachments: [ChatAttachment],
    systemPrompt: String,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = transcript
    _ = attachments
    _ = systemPrompt
    _ = settings
    return AsyncThrowingStream { continuation in
      continuation.yield(.completed(nil))
      continuation.finish()
    }
  }
}

actor InterruptedStreamingRuntime: ChatModelRuntime {
  private let chunks: [String]

  init(chunks: [String] = []) {
    self.chunks = chunks
  }

  func load(configuration: ChatModelConfiguration) async throws {
    _ = configuration
  }

  func unload() async {}

  func clearContext() async {}

  func contextUsage(
    for transcript: ModelContextSnapshot,
    attachments: [ChatAttachment],
    systemPrompt: String
  ) async throws -> ChatContextUsage {
    _ = transcript
    _ = attachments
    _ = systemPrompt
    return ChatContextUsage(usedTokens: 0, tokenLimit: nil)
  }

  func streamReply(
    for transcript: ModelContextSnapshot,
    attachments: [ChatAttachment],
    systemPrompt: String,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = transcript
    _ = attachments
    _ = systemPrompt
    _ = settings
    return AsyncThrowingStream { continuation in
      for chunk in chunks {
        continuation.yield(.chunk(chunk))
      }
      continuation.finish()
    }
  }
}

actor ControlledStreamingRuntime: ChatModelRuntime {
  private let turns: [[ChatModelStreamEvent]]
  private let blockedCallIndexes: Set<Int>
  private var streamContinuations: [Int: CheckedContinuation<Void, Never>] = [:]
  private var releasedCallIndexes: Set<Int> = []
  private var streamReplyCount = 0
  private var contextUsageCount = 0
  private(set) var completedCallIndexes: Set<Int> = []
  private(set) var capturedMessages: [[ProjectedModelContextEntry]] = []
  private(set) var capturedSystemPrompts: [String] = []
  private(set) var capturedToolContexts: [ChatRuntimeToolContext?] = []

  init(turns: [[String]], blockedCallIndexes: Set<Int>) {
    self.turns = turns.map { $0.map(ChatModelStreamEvent.chunk) }
    self.blockedCallIndexes = blockedCallIndexes
  }

  init(eventTurns: [[ChatModelStreamEvent]], blockedCallIndexes: Set<Int>) {
    self.turns = eventTurns
    self.blockedCallIndexes = blockedCallIndexes
  }

  var startedStreamCount: Int {
    streamReplyCount
  }

  var contextUsageRequestCount: Int {
    contextUsageCount
  }

  func load(configuration: ChatModelConfiguration) async throws {
    _ = configuration
  }

  func unload() async {}
  func clearContext() async {}

  func contextUsage(
    for transcript: ModelContextSnapshot,
    attachments: [ChatAttachment],
    systemPrompt: String
  ) async throws -> ChatContextUsage {
    _ = transcript
    _ = attachments
    _ = systemPrompt
    contextUsageCount += 1
    return ChatContextUsage(usedTokens: 0, tokenLimit: nil)
  }

  func releaseStream(callIndex: Int) {
    releasedCallIndexes.insert(callIndex)
    streamContinuations.removeValue(forKey: callIndex)?.resume()
  }

  func streamReply(
    for transcript: ModelContextSnapshot,
    attachments: [ChatAttachment],
    systemPrompt: String,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = attachments
    _ = settings

    capturedMessages.append(
      transcript.projectedEntries(mode: .fullHistory))
    capturedSystemPrompts.append(systemPrompt)
    let callIndex = streamReplyCount
    streamReplyCount += 1
    let events = turns[min(callIndex, turns.count - 1)]
    let shouldBlock = blockedCallIndexes.contains(callIndex)

    return AsyncThrowingStream { continuation in
      let task = Task {
        if shouldBlock {
          await withCheckedContinuation { release in
            Task {
              self.storeStreamContinuation(release, callIndex: callIndex)
            }
          }
        }

        guard !Task.isCancelled else {
          continuation.finish(throwing: CancellationError())
          self.recordStreamFinished(callIndex: callIndex)
          return
        }

        for event in events {
          continuation.yield(event)
        }
        continuation.yield(
          .completed(
            ChatGenerationMetrics(
              generatedTokenCount: events.count,
              tokensPerSecond: 100,
              durationMs: Double(events.count) * 10
            )
          )
        )
        continuation.finish()
        self.recordStreamFinished(callIndex: callIndex)
      }

      continuation.onTermination = { _ in
        task.cancel()
      }
    }
  }

  func streamReply(
    for transcript: ModelContextSnapshot,
    attachments: [ChatAttachment],
    systemPrompt: String,
    settings: ChatGenerationSettings,
    toolContext: ChatRuntimeToolContext?
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    capturedToolContexts.append(toolContext)
    return try await streamReply(
      for: transcript,
      attachments: attachments,
      systemPrompt: systemPrompt,
      settings: settings
    )
  }

  private func storeStreamContinuation(
    _ continuation: CheckedContinuation<Void, Never>,
    callIndex: Int
  ) {
    guard !releasedCallIndexes.contains(callIndex) else {
      continuation.resume()
      return
    }
    streamContinuations[callIndex] = continuation
    Task {
      try? await Task.sleep(for: .seconds(2))
      self.releaseStream(callIndex: callIndex)
    }
  }

  private func recordStreamFinished(callIndex: Int) {
    completedCallIndexes.insert(callIndex)
  }
}

actor PartialFailingStreamingRuntime: ChatModelRuntime {
  private let chunks: [String]

  init(chunks: [String]) {
    self.chunks = chunks
  }

  func load(configuration: ChatModelConfiguration) async throws {
    _ = configuration
  }

  func unload() async {}
  func clearContext() async {}

  func contextUsage(
    for transcript: ModelContextSnapshot,
    attachments: [ChatAttachment],
    systemPrompt: String
  ) async throws -> ChatContextUsage {
    _ = transcript
    _ = attachments
    _ = systemPrompt
    return ChatContextUsage(usedTokens: 0, tokenLimit: nil)
  }

  func streamReply(
    for transcript: ModelContextSnapshot,
    attachments: [ChatAttachment],
    systemPrompt: String,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = transcript
    _ = attachments
    _ = systemPrompt
    _ = settings

    return AsyncThrowingStream { continuation in
      for chunk in chunks {
        continuation.yield(.chunk(chunk))
      }
      continuation.finish(throwing: ChatSessionFakeChatModelRuntimeError.streamFailed)
    }
  }
}

actor DelayedClearContextRuntime: ChatModelRuntime {
  private var clearContextContinuation: CheckedContinuation<Void, Never>?
  private(set) var didStartClearContext = false
  private(set) var didFinishClearContext = false
  private(set) var streamReplyCount = 0

  func load(configuration: ChatModelConfiguration) async throws {
    _ = configuration
  }

  func unload() async {}

  func clearContext() async {
    didStartClearContext = true
    await withCheckedContinuation { continuation in
      clearContextContinuation = continuation
      Task {
        try? await Task.sleep(for: .seconds(2))
        self.releaseClearContext()
      }
    }
    didFinishClearContext = true
  }

  func releaseClearContext() {
    clearContextContinuation?.resume()
    clearContextContinuation = nil
  }

  func contextUsage(
    for transcript: ModelContextSnapshot,
    attachments: [ChatAttachment],
    systemPrompt: String
  ) async throws -> ChatContextUsage {
    _ = transcript
    _ = attachments
    _ = systemPrompt
    return ChatContextUsage(usedTokens: 42, tokenLimit: nil)
  }

  func streamReply(
    for transcript: ModelContextSnapshot,
    attachments: [ChatAttachment],
    systemPrompt: String,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = transcript
    _ = attachments
    _ = systemPrompt
    _ = settings
    streamReplyCount += 1
    return AsyncThrowingStream { continuation in
      continuation.yield(.completed(nil))
      continuation.finish()
    }
  }
}

final class BlockingFirstAttachmentLoader: ChatAttachmentLoading, @unchecked Sendable {
  private let lock = NSLock()
  private let firstLoadRelease = DispatchSemaphore(value: 0)
  private var _startedCount = 0
  private var _completedCount = 0

  var startedCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return _startedCount
  }

  var completedCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return _completedCount
  }

  func loadAttachments(
    from urls: [URL],
    existingAttachments: [ChatAttachment]
  ) throws -> [ChatAttachment] {
    _ = existingAttachments
    lock.lock()
    _startedCount += 1
    let callNumber = _startedCount
    lock.unlock()

    if callNumber == 1 {
      guard firstLoadRelease.wait(timeout: .now() + .seconds(2)) == .success else {
        throw TestWaitTimeoutError()
      }
    }

    lock.lock()
    _completedCount += 1
    lock.unlock()

    guard let url = urls.first else {
      return []
    }
    return [
      ChatAttachment(
        url: url,
        displayName: url.lastPathComponent,
        kind: .text,
        content: callNumber == 1 ? "first" : "second"
      )
    ]
  }

  func releaseFirstLoad() {
    firstLoadRelease.signal()
  }
}

actor ChatSessionFakeChatModelRuntime: ChatModelRuntime {
  private let turns: [[ChatModelStreamEvent]]
  private let failingStreamReplyCalls: Set<Int>
  private let debugSnapshot: RuntimeCacheDebugSnapshot?
  private var streamReplyCount = 0
  private(set) var capturedMessages: [[ProjectedModelContextEntry]] = []
  private(set) var capturedAttachments: [[ChatAttachment]] = []
  private(set) var capturedSystemPrompts: [String] = []
  private(set) var capturedToolContexts: [ChatRuntimeToolContext?] = []
  private(set) var capturedContextUsageSystemPrompts: [String] = []

  init(chunks: [String] = [], debugSnapshot: RuntimeCacheDebugSnapshot? = nil) {
    self.turns = [chunks.map(ChatModelStreamEvent.chunk)]
    self.failingStreamReplyCalls = []
    self.debugSnapshot = debugSnapshot
  }

  init(
    eventTurns: [[ChatModelStreamEvent]],
    failingStreamReplyCalls: Set<Int> = [],
    debugSnapshot: RuntimeCacheDebugSnapshot? = nil
  ) {
    self.turns = eventTurns
    self.failingStreamReplyCalls = failingStreamReplyCalls
    self.debugSnapshot = debugSnapshot
  }

  func load(configuration: ChatModelConfiguration) async throws {
    _ = configuration
  }

  func unload() async {}

  func clearContext() async {}

  func runtimeCacheDebugSnapshot() async -> RuntimeCacheDebugSnapshot? {
    debugSnapshot
  }

  func contextUsage(
    for transcript: ModelContextSnapshot,
    attachments: [ChatAttachment],
    systemPrompt: String
  ) async throws -> ChatContextUsage {
    capturedContextUsageSystemPrompts.append(systemPrompt)
    let usedTokens =
      ([systemPrompt] + transcript.entries.map(\.frozenContent.content) + attachments.map(\.content))
      .joined(separator: " ")
      .split(whereSeparator: \.isWhitespace)
      .count
    return ChatContextUsage(usedTokens: usedTokens, tokenLimit: nil)
  }

  func streamReply(
    for transcript: ModelContextSnapshot,
    attachments: [ChatAttachment],
    systemPrompt: String,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = settings

    capturedMessages.append(
      transcript.projectedEntries(mode: .fullHistory))
    capturedAttachments.append(attachments)
    capturedSystemPrompts.append(systemPrompt)
    let callIndex = streamReplyCount
    let events = turns[min(callIndex, turns.count - 1)]
    streamReplyCount += 1

    if failingStreamReplyCalls.contains(callIndex) {
      return AsyncThrowingStream { continuation in
        continuation.finish(throwing: ChatSessionFakeChatModelRuntimeError.streamFailed)
      }
    }

    return AsyncThrowingStream { continuation in
      for event in events {
        continuation.yield(event)
      }
      continuation.yield(
        .completed(
          ChatGenerationMetrics(
            generatedTokenCount: events.count,
            tokensPerSecond: 100,
            durationMs: Double(events.count) * 10
          )
        )
      )
      continuation.finish()
    }
  }

  func streamReply(
    for transcript: ModelContextSnapshot,
    attachments: [ChatAttachment],
    systemPrompt: String,
    settings: ChatGenerationSettings,
    toolContext: ChatRuntimeToolContext?
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    capturedToolContexts.append(toolContext)
    return try await streamReply(
      for: transcript,
      attachments: attachments,
      systemPrompt: systemPrompt,
      settings: settings
    )
  }

}

enum ChatSessionFakeChatModelRuntimeError: Error {
  case streamFailed
}
