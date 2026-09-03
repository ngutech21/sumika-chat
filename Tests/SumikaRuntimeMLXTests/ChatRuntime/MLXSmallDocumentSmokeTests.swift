import Foundation
import MLX
import XCTest

@testable import SumikaCore
@testable import SumikaRuntimeMLX

nonisolated final class MLXSmallDocumentSmokeTests: XCTestCase {
  func testInstalledModelReadsDocumentEnding() async throws {
    guard let modelID = ProcessInfo.processInfo.environment["SUMIKA_DOCUMENT_SMOKE_MODEL_ID"] else {
      throw XCTSkip(
        "Set SUMIKA_DOCUMENT_SMOKE_MODEL_ID to run an installed-model document smoke test.")
    }
    let model = try XCTUnwrap(ManagedModelCatalog.model(id: modelID))
    let modelsRoot =
      ProcessInfo.processInfo.environment["SUMIKA_DOCUMENT_SMOKE_MODELS_PATH"]
      .map { URL(filePath: $0) } ?? LocalModelDirectory.defaultBaseURL
    let directory = modelsRoot.appending(path: model.localDirectoryName)
    guard
      FileManager.default.fileExists(
        atPath: directory.appending(path: "config.json").path(percentEncoded: false))
    else {
      throw XCTSkip(
        "The selected smoke-test model is not installed at \(directory.path(percentEncoded: false))."
      )
    }
    let root = FileManager.default.temporaryDirectory.appending(
      path: "sumika-document-smoke-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let traceURL = root.appending(path: "mlx-trace.jsonl")
    let runtime = MLXChatRuntime(
      debugTraceStore: MLXDebugTraceStore(fileURL: traceURL, isEnabled: { true }))
    do {
      try await runtime.load(
        configuration: ChatModelConfiguration(
          localModelDirectory: directory,
          contextTokenLimit: min(
            16_384, LocalModelDirectory.readContextTokenLimit(from: directory) ?? 16_384),
          supportsImageInput: model.supportsImageInput,
          reasoningTraceFormat: model.reasoningTraceFormat,
          supportsHistoricalReasoningPreservation: model.supportsHistoricalReasoningPreservation,
          reasoningCapability: model.reasoningCapability,
          thinkingBudgetPolicy: model.thinkingBudgetPolicy
        ))
      try await Self.verifyEnding(runtime: runtime, model: model, root: root, traceURL: traceURL)
      await runtime.unload()
    } catch {
      await runtime.unload()
      throw error
    }
  }

  private static func verifyEnding(
    runtime: MLXChatRuntime, model: ManagedModel, root: URL, traceURL: URL
  ) async throws {
    let suffix = "\nFinal shipment code: COBALT-731. Destination: North Harbor.\n"
    let paragraph =
      "Archive note: this entry records routine inventory checks. Each shipment is inspected and its destination is confirmed before dispatch.\n"
    let markdown =
      String(String(repeating: paragraph, count: 250).prefix(31_950 - suffix.count)) + suffix
    let source = root.appending(path: "archive.md")
    try Data(markdown.utf8).write(to: source)
    let attachments = try await ChatAttachmentLoader(
      attachmentStore: ChatAttachmentStore(baseURL: root.appending(path: "stored"))
    )
    .loadAttachments(from: [source], existingAttachments: [])
    let context = ChatModelContextBuilder().currentPromptContext(
      mode: .chat, focusedFileState: .empty, attachments: attachments)
    let prompt =
      "Read the attached archive. What shipment code and destination appear in its final line? Reply with only those two values."
    let entry = try ModelFacingPromptRenderer.userPromptEntry(
      prompt: prompt, attachments: attachments,
      systemContext: CurrentPromptContextRenderer.renderSupportingContext(context),
      currentPromptContext: context
    )
    XCTAssertTrue(entry.frozenContent.content.contains("COBALT-731"))
    let projection = ModelPromptProjection(entries: [entry])
    let recommended = ModelSettingsResolver.recommendedSettings(for: model, generationConfig: nil)
    var settings = recommended.modeSettings.chat.generationSettings
    settings.temperature = 0
    let savedSettings = settings
    let startedAt = Date()
    Memory.peakMemory = 0
    var firstEventSeconds: Double?
    var firstVisibleSeconds: Double?
    var output = ""
    let stream = try await runtime.streamReply(
      for: projection, attachments: attachments,
      promptPlan: ChatRuntimePromptPlan(
        stableInstructions: recommended.modeSettings.chat.systemPrompt),
      settings: settings, interactionMode: .chat
    )
    for try await event in stream {
      switch event {
      case .chunk(let text):
        if firstEventSeconds == nil { firstEventSeconds = Date().timeIntervalSince(startedAt) }
        if firstVisibleSeconds == nil { firstVisibleSeconds = Date().timeIntervalSince(startedAt) }
        output += text
      case .thinkingChunk:
        if firstEventSeconds == nil { firstEventSeconds = Date().timeIntervalSince(startedAt) }
      case .outputLimitReached:
        XCTFail("Document smoke test reached its output limit")
      case .thinkingCompleted, .toolCall, .completed:
        break
      }
    }
    let correct = output.contains("COBALT-731") && output.contains("North Harbor")
    print(
      "DOCUMENT SMOKE \(model.id): characters=\(markdown.count), firstEventSeconds=\(firstEventSeconds ?? -1), firstVisibleSeconds=\(firstVisibleSeconds ?? -1), peakMLXBytes=\(Memory.peakMemory), endingCorrect=\(correct), output=\(output)"
    )
    let records = try String(contentsOf: traceURL, encoding: .utf8).split(separator: "\n")
      .compactMap {
        try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
      }
    if let response = records.last(where: { $0["kind"] as? String == "mlx_response" }),
      let budget = response["contextBudget"]
    {
      print("DOCUMENT SMOKE measured context budget: \(budget)")
    }
    XCTAssertTrue(
      correct, "The response must include both facts from the document ending: \(output)")
    XCTAssertEqual(settings, savedSettings)
  }
}
