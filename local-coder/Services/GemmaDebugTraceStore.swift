import Foundation
import LocalCoderCore

actor GemmaDebugTraceStore: TurnTracing {
  static let shared = GemmaDebugTraceStore()

  nonisolated static var isEnabled: Bool {
    let value = ProcessInfo.processInfo.environment["LOCAL_CODER_DEBUG_TRACE"] ?? ""
    return ["1", "true", "yes", "on"].contains(value.lowercased())
  }

  private let fileURL: URL
  private let maxFieldCharacters = 80_000

  init(fileURL: URL = GemmaDebugTraceStore.defaultFileURL()) {
    self.fileURL = fileURL
  }

  func traceRequest(
    id: UUID,
    history: [(role: String, content: String)],
    prompt: String,
    settings: ChatGenerationSettings,
    contextTokenLimit: Int?
  ) async {
    guard Self.isEnabled else {
      return
    }

    let truncatedPrompt = truncated(prompt)
    var request: [String: Any] = [
      "id": id.uuidString,
      "timestamp": timestamp(),
      "kind": "gemma_request",
      "settings": [
        "maxTokens": settings.maxTokens,
        "temperature": settings.temperature,
        "topP": settings.topP,
        "topK": settings.topK,
      ],
      "history": history.map(traceMessage(from:)),
      "prompt": truncatedPrompt.value,
      "promptTruncated": truncatedPrompt.truncated,
    ]
    if let contextTokenLimit {
      request["contextTokenLimit"] = contextTokenLimit
    }
    append(request)
  }

  func traceResponse(
    id: UUID,
    output: String,
    metrics: ChatGenerationMetrics?,
    error: String? = nil
  ) async {
    guard Self.isEnabled else {
      return
    }

    let truncatedOutput = truncated(output)
    var response: [String: Any] = [
      "id": id.uuidString,
      "timestamp": timestamp(),
      "kind": "gemma_response",
      "output": truncatedOutput.value,
      "outputTruncated": truncatedOutput.truncated,
    ]
    if let metrics {
      response["metrics"] = [
        "generatedTokenCount": metrics.generatedTokenCount,
        "tokensPerSecond": metrics.tokensPerSecond,
      ]
    }
    if let error {
      response["error"] = error
    }
    append(response)
  }

  func recordTurnTraceEvent(_ event: TurnTraceEvent) async {
    traceTurnEvent(event)
  }

  func traceTurnEvent(_ event: TurnTraceEvent) {
    guard Self.isEnabled else {
      return
    }

    var trace: [String: Any] = [
      "timestamp": timestamp(),
      "kind": "turn_trace",
      "phase": event.phase.rawValue,
      "durationMs": event.durationMs,
    ]
    if let turnID = event.turnID {
      trace["turnID"] = turnID.uuidString
    }
    if let generationID = event.generationID {
      trace["generationID"] = generationID.uuidString
    }
    if let promptBytes = event.promptBytes {
      trace["promptBytes"] = promptBytes
    }
    if let promptTokens = event.promptTokens {
      trace["promptTokens"] = promptTokens
    }
    if let messageCount = event.messageCount {
      trace["messageCount"] = messageCount
    }
    if let toolLoopIteration = event.toolLoopIteration {
      trace["toolLoopIteration"] = toolLoopIteration
    }
    if let toolName = event.toolName {
      trace["toolName"] = toolName
    }
    if let ttftMs = event.ttftMs {
      trace["ttftMs"] = ttftMs
    }
    if let tokensPerSecond = event.tokensPerSecond {
      trace["tokensPerSecond"] = tokensPerSecond
    }
    if let cacheMode = event.cacheMode {
      trace["cacheMode"] = cacheMode
    }
    if let interactionMode = event.interactionMode {
      trace["interactionMode"] = interactionMode.rawValue
    }
    if let contextSignature = event.contextSignature {
      trace["contextSignature"] = contextSignature
    }
    if let previousContextSignature = event.previousContextSignature {
      trace["previousContextSignature"] = previousContextSignature
    }
    if let appendOnly = event.appendOnly {
      trace["appendOnly"] = appendOnly
    }
    if let reusedMessageCount = event.reusedMessageCount {
      trace["reusedMessageCount"] = reusedMessageCount
    }
    if let appendedMessageCount = event.appendedMessageCount {
      trace["appendedMessageCount"] = appendedMessageCount
    }
    if let mismatchReason = event.mismatchReason {
      trace["mismatchReason"] = mismatchReason
    }
    if let firstMismatchIndex = event.firstMismatchIndex {
      trace["firstMismatchIndex"] = firstMismatchIndex
    }
    if let systemPromptChanged = event.systemPromptChanged {
      trace["systemPromptChanged"] = systemPromptChanged
    }
    if let focusedContextChanged = event.focusedContextChanged {
      trace["focusedContextChanged"] = focusedContextChanged
    }
    append(trace)
  }

  private func traceMessage(from message: (role: String, content: String)) -> [String: Any] {
    let truncatedContent = truncated(message.content)
    return [
      "role": message.role,
      "content": truncatedContent.value,
      "truncated": truncatedContent.truncated,
    ]
  }

  private func truncated(_ value: String) -> (value: String, truncated: Bool) {
    guard value.count > maxFieldCharacters else {
      return (value, false)
    }

    return (String(value.prefix(maxFieldCharacters)), true)
  }

  private func timestamp() -> String {
    ISO8601DateFormatter().string(from: Date())
  }

  private func append(_ value: [String: Any]) {
    do {
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )

      var data = try JSONSerialization.data(
        withJSONObject: value,
        options: [.sortedKeys, .withoutEscapingSlashes]
      )
      data.append(0x0A)

      if FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) {
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
      } else {
        try data.write(to: fileURL, options: .atomic)
      }
    } catch {
      // Debug tracing must never affect model generation.
    }
  }

  nonisolated private static func defaultFileURL() -> URL {
    if let traceFile = ProcessInfo.processInfo.environment["LOCAL_CODER_DEBUG_TRACE_FILE"],
      !traceFile.isEmpty
    {
      return URL(filePath: traceFile, directoryHint: .notDirectory)
    }
    if let traceBasename = ProcessInfo.processInfo.environment["LOCAL_CODER_DEBUG_TRACE_BASENAME"],
      !traceBasename.isEmpty,
      !traceBasename.contains("/")
    {
      return debugDirectory()
        .appending(path: "traces", directoryHint: .isDirectory)
        .appending(path: traceBasename, directoryHint: .notDirectory)
    }

    return debugDirectory()
      .appending(path: "gemma-trace.jsonl", directoryHint: .notDirectory)
  }

  nonisolated private static func debugDirectory() -> URL {
    URL.applicationSupportDirectory
      .appending(path: "local-coder", directoryHint: .isDirectory)
      .appending(path: "debug", directoryHint: .isDirectory)
  }
}
