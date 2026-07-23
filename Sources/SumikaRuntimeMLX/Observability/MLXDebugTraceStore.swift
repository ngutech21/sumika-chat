import Foundation
import SumikaCore

actor MLXDebugTraceStore: TurnTracing {
  private static var isEnabled: Bool {
    let value = ProcessInfo.processInfo.environment["SUMIKA_DEBUG_TRACE"] ?? ""
    return ["1", "true", "yes", "on"].contains(value.lowercased())
  }

  private let fileURL: URL
  private let maxFieldCharacters = 80_000

  init() {
    self.fileURL = Self.defaultFileURL()
  }

  init(fileURL: URL) {
    self.fileURL = fileURL
  }

  func traceRequest(
    id: UUID,
    history: [(role: String, content: String)],
    prompt: String,
    settings: ChatGenerationSettings,
    contextTokenLimit: Int?,
    imageAttachments: [ChatAttachment] = []
  ) async {
    guard Self.isEnabled else {
      return
    }

    let truncatedPrompt = truncated(prompt)
    var settingsTrace: [String: Any] = [
      "maxTokens": settings.maxTokens,
      "temperature": settings.temperature,
      "topP": settings.topP,
      "topK": settings.topK,
      "repetitionPenalty": settings.repetitionPenalty,
    ]
    if let maxKVSize = settings.maxKVSize {
      settingsTrace["maxKVSize"] = maxKVSize
    }
    var request: [String: Any] = [
      "id": id.uuidString,
      "timestamp": timestamp(),
      "kind": "mlx_request",
      "settings": settingsTrace,
      "history": history.map(traceMessage(from:)),
      "prompt": truncatedPrompt.value,
      "promptTruncated": truncatedPrompt.truncated,
    ]
    if let contextTokenLimit {
      request["contextTokenLimit"] = contextTokenLimit
    }
    let imageMetadata = traceImageAttachments(from: imageAttachments)
    if !imageMetadata.isEmpty {
      request["imageInputs"] = imageMetadata
      request["imageCount"] = imageMetadata.count
      request["imageByteCount"] = MLXHistoryRenderer.imageByteCount(from: imageAttachments)
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
      "kind": "mlx_response",
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
    guard Self.isEnabled else {
      return
    }

    var trace: [String: Any] = [
      "timestamp": timestamp(),
      "kind": "turn_trace",
      "phase": event.phase.rawValue,
      "durationMs": event.durationMs,
    ]
    let optionalFields: [(String, Any?)] = [
      ("turnID", event.turnID?.uuidString),
      ("generationID", event.generationID?.uuidString),
      ("promptBytes", event.promptBytes),
      ("promptTokens", event.promptTokens),
      ("messageCount", event.messageCount),
      ("toolLoopIteration", event.toolLoopIteration),
      ("toolName", event.toolName),
      ("ttftMs", event.ttftMs),
      ("tokensPerSecond", event.tokensPerSecond),
      ("cacheMode", event.cacheMode),
      ("cacheReason", event.cacheReason),
      ("memoryClearReason", event.memoryClearReason),
      ("interactionMode", event.interactionMode?.rawValue),
      ("selectedMCPServerIDs", event.selectedMCPServerIDs?.map(\.uuidString)),
      ("activeMCPToolCount", event.activeMCPToolCount),
      ("contextSignature", event.contextSignature),
      ("previousContextSignature", event.previousContextSignature),
      ("appendOnly", event.appendOnly),
      ("reusedMessageCount", event.reusedMessageCount),
      ("appendedMessageCount", event.appendedMessageCount),
      ("mismatchReason", event.mismatchReason),
      ("firstMismatchIndex", event.firstMismatchIndex),
      ("systemPromptChanged", event.systemPromptChanged),
      ("toolCallFormat", event.toolCallFormat),
      ("toolValidationStatus", event.toolValidationStatus),
      ("toolValidationError", event.toolValidationError),
      ("toolOriginalName", event.toolOriginalName),
      ("toolArgumentKeys", event.toolArgumentKeys),
      ("toolArguments", event.toolArguments?.map(traceToolArgument(from:))),
      ("imageCount", event.imageCount),
      ("imageTypes", event.imageTypes),
      ("imageByteCount", event.imageByteCount),
    ]
    for (key, value) in optionalFields {
      if let value {
        trace[key] = value
      }
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

  private func traceToolArgument(from argument: ToolArgumentTrace) -> [String: Any] {
    [
      "name": argument.name,
      "valueType": argument.valueType,
      "preview": argument.preview,
      "previewTruncated": argument.previewTruncated,
    ]
  }

  private func traceImageAttachments(from attachments: [ChatAttachment]) -> [[String: Any]] {
    attachments.filter { $0.kind == .image }.map { attachment in
      var trace: [String: Any] = [
        "attachmentID": attachment.id.uuidString,
        "name": attachment.displayName,
        "byteCount": attachment.byteSize,
        "sha256": attachment.contentSHA256,
      ]
      if let mimeType = attachment.mimeType {
        trace["mimeType"] = mimeType
      }
      return trace
    }
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

  private static func defaultFileURL() -> URL {
    if let traceFile = ProcessInfo.processInfo.environment["SUMIKA_DEBUG_TRACE_FILE"],
      !traceFile.isEmpty
    {
      return URL(filePath: traceFile, directoryHint: .notDirectory)
    }
    if let traceBasename = ProcessInfo.processInfo.environment["SUMIKA_DEBUG_TRACE_BASENAME"],
      !traceBasename.isEmpty,
      !traceBasename.contains("/")
    {
      return debugDirectory()
        .appending(path: "traces", directoryHint: .isDirectory)
        .appending(path: traceBasename, directoryHint: .notDirectory)
    }

    return debugDirectory()
      .appending(path: "mlx-trace.jsonl", directoryHint: .notDirectory)
  }

  private static func debugDirectory() -> URL {
    URL.applicationSupportDirectory
      .appending(path: "Sumika", directoryHint: .isDirectory)
      .appending(path: "debug", directoryHint: .isDirectory)
  }
}
