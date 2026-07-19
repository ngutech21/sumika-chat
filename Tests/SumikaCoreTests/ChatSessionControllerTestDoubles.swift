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

  func streamReply(
    for transcript: ModelPromptProjection,
    attachments: [ChatAttachment],
    promptPlan: ChatRuntimePromptPlan,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = transcript
    _ = attachments
    _ = promptPlan
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
  func load(configuration: ChatModelConfiguration) async throws {
    _ = configuration
  }

  func unload() async {}
  func clearContext() async {}

  func streamReply(
    for transcript: ModelPromptProjection,
    attachments: [ChatAttachment],
    promptPlan: ChatRuntimePromptPlan,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = transcript
    _ = attachments
    _ = promptPlan
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

  func streamReply(
    for transcript: ModelPromptProjection,
    attachments: [ChatAttachment],
    promptPlan: ChatRuntimePromptPlan,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = transcript
    _ = attachments
    _ = promptPlan
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

  func streamReply(
    for transcript: ModelPromptProjection,
    attachments: [ChatAttachment],
    promptPlan: ChatRuntimePromptPlan,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = transcript
    _ = attachments
    _ = promptPlan
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
  private(set) var completedCallIndexes: Set<Int> = []
  private(set) var capturedMessages: [[ProjectedModelContextEntry]] = []
  private(set) var capturedSystemPrompts: [String] = []
  private(set) var capturedToolContexts: [ChatRuntimeToolContext?] = []
  private(set) var capturedPromptPlans: [ChatRuntimePromptPlan] = []

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

  func load(configuration: ChatModelConfiguration) async throws {
    _ = configuration
  }

  func unload() async {}
  func clearContext() async {}

  func streamReply(
    for transcript: ModelPromptProjection,
    attachments: [ChatAttachment],
    promptPlan: ChatRuntimePromptPlan,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = attachments
    _ = settings

    capturedPromptPlans.append(promptPlan)
    capturedToolContexts.append(promptPlan.toolContext)
    capturedMessages.append(
      transcript.projectedEntries(mode: .fullHistory))
    capturedSystemPrompts.append(promptPlan.stableInstructions)
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

  func releaseStream(callIndex: Int) {
    releasedCallIndexes.insert(callIndex)
    streamContinuations.removeValue(forKey: callIndex)?.resume()
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

  func streamReply(
    for transcript: ModelPromptProjection,
    attachments: [ChatAttachment],
    promptPlan: ChatRuntimePromptPlan,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = transcript
    _ = attachments
    _ = promptPlan
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

  func streamReply(
    for transcript: ModelPromptProjection,
    attachments: [ChatAttachment],
    promptPlan: ChatRuntimePromptPlan,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = transcript
    _ = attachments
    _ = promptPlan
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
  private let automaticallyCompletes: Bool
  private var streamReplyCount = 0
  private(set) var capturedMessages: [[ProjectedModelContextEntry]] = []
  private(set) var capturedAttachments: [[ChatAttachment]] = []
  private(set) var capturedSystemPrompts: [String] = []
  private(set) var capturedGenerationSettings: [ChatGenerationSettings] = []
  private(set) var capturedToolContexts: [ChatRuntimeToolContext?] = []
  private(set) var capturedPromptPlans: [ChatRuntimePromptPlan] = []

  init(
    chunks: [String] = [],
    debugSnapshot: RuntimeCacheDebugSnapshot? = nil,
    automaticallyCompletes: Bool = true
  ) {
    self.turns = [chunks.map(ChatModelStreamEvent.chunk)]
    self.failingStreamReplyCalls = []
    self.debugSnapshot = debugSnapshot
    self.automaticallyCompletes = automaticallyCompletes
  }

  init(
    eventTurns: [[ChatModelStreamEvent]],
    failingStreamReplyCalls: Set<Int> = [],
    debugSnapshot: RuntimeCacheDebugSnapshot? = nil,
    automaticallyCompletes: Bool = true
  ) {
    self.turns = eventTurns
    self.failingStreamReplyCalls = failingStreamReplyCalls
    self.debugSnapshot = debugSnapshot
    self.automaticallyCompletes = automaticallyCompletes
  }

  func load(configuration: ChatModelConfiguration) async throws {
    _ = configuration
  }

  func unload() async {}

  func clearContext() async {}

  func runtimeCacheDebugSnapshot() async -> RuntimeCacheDebugSnapshot? {
    debugSnapshot
  }

  func streamReply(
    for transcript: ModelPromptProjection,
    attachments: [ChatAttachment],
    promptPlan: ChatRuntimePromptPlan,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    capturedPromptPlans.append(promptPlan)
    capturedToolContexts.append(promptPlan.toolContext)
    capturedMessages.append(
      transcript.projectedEntries(mode: .fullHistory))
    capturedAttachments.append(attachments)
    capturedSystemPrompts.append(promptPlan.stableInstructions)
    capturedGenerationSettings.append(settings)
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
      if automaticallyCompletes {
        continuation.yield(
          .completed(
            ChatGenerationMetrics(
              generatedTokenCount: events.count,
              tokensPerSecond: 100,
              durationMs: Double(events.count) * 10
            )
          )
        )
      }
      continuation.finish()
    }
  }

}

enum ChatSessionFakeChatModelRuntimeError: Error {
  case streamFailed
}
