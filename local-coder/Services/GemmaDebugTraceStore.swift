import Foundation
import LocalCoderCore

actor GemmaDebugTraceStore {
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
    URL.applicationSupportDirectory
      .appending(path: "local-coder", directoryHint: .isDirectory)
      .appending(path: "debug", directoryHint: .isDirectory)
      .appending(path: "gemma-trace.jsonl", directoryHint: .notDirectory)
  }
}
