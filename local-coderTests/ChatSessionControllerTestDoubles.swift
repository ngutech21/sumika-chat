import Foundation

@testable import local_coder

actor NonCooperativeStreamingRuntime: ChatModelRuntime {
  private let chunks: [String]
  private var streamContinuation: CheckedContinuation<Void, Never>?
  private var didReleaseChunks = false
  private(set) var didStartStreaming = false

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
    for messages: [ChatMessage],
    attachments: [ChatAttachment],
    systemPrompt: String
  ) async throws -> ChatContextUsage {
    _ = messages
    _ = attachments
    _ = systemPrompt
    return ChatContextUsage(usedTokens: 0, tokenLimit: nil)
  }

  func streamReply(
    for messages: [ChatMessage],
    attachments: [ChatAttachment],
    systemPrompt: String,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = messages
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
      }
    }
  }

  private func storeStreamContinuation(_ continuation: CheckedContinuation<Void, Never>) {
    if didReleaseChunks {
      continuation.resume()
      return
    }
    streamContinuation = continuation
  }
}

actor ControlledContextUsageRuntime: ChatModelRuntime {
  private var contextUsageContinuations: [CheckedContinuation<ChatContextUsage, Never>] = []

  var contextUsageRequestCount: Int {
    contextUsageContinuations.count
  }

  func load(configuration: ChatModelConfiguration) async throws {
    _ = configuration
  }

  func unload() async {}
  func clearContext() async {}

  func contextUsage(
    for messages: [ChatMessage],
    attachments: [ChatAttachment],
    systemPrompt: String
  ) async throws -> ChatContextUsage {
    _ = messages
    _ = attachments
    _ = systemPrompt
    return await withCheckedContinuation { continuation in
      contextUsageContinuations.append(continuation)
    }
  }

  func resolveContextUsage(at index: Int, with usage: ChatContextUsage) {
    guard contextUsageContinuations.indices.contains(index) else {
      return
    }
    let continuation = contextUsageContinuations.remove(at: index)
    continuation.resume(returning: usage)
  }

  func streamReply(
    for messages: [ChatMessage],
    attachments: [ChatAttachment],
    systemPrompt: String,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = messages
    _ = attachments
    _ = systemPrompt
    _ = settings
    return AsyncThrowingStream { continuation in
      continuation.finish()
    }
  }
}

actor DelayedClearContextRuntime: ChatModelRuntime {
  private var clearContextContinuation: CheckedContinuation<Void, Never>?
  private(set) var didStartClearContext = false

  func load(configuration: ChatModelConfiguration) async throws {
    _ = configuration
  }

  func unload() async {}

  func clearContext() async {
    didStartClearContext = true
    await withCheckedContinuation { continuation in
      clearContextContinuation = continuation
    }
  }

  func releaseClearContext() {
    clearContextContinuation?.resume()
    clearContextContinuation = nil
  }

  func contextUsage(
    for messages: [ChatMessage],
    attachments: [ChatAttachment],
    systemPrompt: String
  ) async throws -> ChatContextUsage {
    _ = messages
    _ = attachments
    _ = systemPrompt
    return ChatContextUsage(usedTokens: 42, tokenLimit: nil)
  }

  func streamReply(
    for messages: [ChatMessage],
    attachments: [ChatAttachment],
    systemPrompt: String,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = messages
    _ = attachments
    _ = systemPrompt
    _ = settings
    return AsyncThrowingStream { continuation in
      continuation.finish()
    }
  }
}

final class BlockingFirstAttachmentLoader: ChatAttachmentLoading, @unchecked Sendable {
  private let lock = NSLock()
  private let firstLoadRelease = DispatchSemaphore(value: 0)
  private var _startedCount = 0

  var startedCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return _startedCount
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
      firstLoadRelease.wait()
    }

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

  func extractDroppedAttachments(from draft: String) -> DroppedAttachmentExtraction {
    DroppedAttachmentExtraction(cleanedDraft: draft)
  }

  func releaseFirstLoad() {
    firstLoadRelease.signal()
  }
}

actor ChatSessionFakeChatModelRuntime: ChatModelRuntime {
  private let turns: [[String]]
  private let failingStreamReplyCalls: Set<Int>
  private var streamReplyCount = 0
  private(set) var capturedMessages: [[ChatMessage]] = []
  private(set) var capturedSystemPrompts: [String] = []

  init(chunks: [String] = []) {
    self.turns = [chunks]
    self.failingStreamReplyCalls = []
  }

  init(turns: [[String]], failingStreamReplyCalls: Set<Int> = []) {
    self.turns = turns
    self.failingStreamReplyCalls = failingStreamReplyCalls
  }

  func load(configuration: ChatModelConfiguration) async throws {
    _ = configuration
  }

  func unload() async {}

  func clearContext() async {}

  func contextUsage(
    for messages: [ChatMessage],
    attachments: [ChatAttachment],
    systemPrompt: String
  ) async throws -> ChatContextUsage {
    let usedTokens = ([systemPrompt] + messages.map(\.content) + attachments.map(\.content))
      .joined(separator: " ")
      .split(whereSeparator: \.isWhitespace)
      .count
    return ChatContextUsage(usedTokens: usedTokens, tokenLimit: nil)
  }

  func streamReply(
    for messages: [ChatMessage],
    attachments: [ChatAttachment],
    systemPrompt: String,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = attachments
    _ = settings

    capturedMessages.append(messages)
    capturedSystemPrompts.append(systemPrompt)
    let callIndex = streamReplyCount
    let chunks = turns[min(callIndex, turns.count - 1)]
    streamReplyCount += 1

    if failingStreamReplyCalls.contains(callIndex) {
      return AsyncThrowingStream { continuation in
        continuation.finish(throwing: ChatSessionFakeChatModelRuntimeError.streamFailed)
      }
    }

    return AsyncThrowingStream { continuation in
      for chunk in chunks {
        continuation.yield(.chunk(chunk))
      }
      continuation.yield(
        .completed(ChatGenerationMetrics(generatedTokenCount: chunks.count, tokensPerSecond: 100))
      )
      continuation.finish()
    }
  }
}

enum ChatSessionFakeChatModelRuntimeError: Error {
  case streamFailed
}
