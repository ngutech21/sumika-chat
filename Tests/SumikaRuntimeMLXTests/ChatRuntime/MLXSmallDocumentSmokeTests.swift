import Foundation
import MLX
import XCTest

@testable import SumikaCore
@testable import SumikaRuntimeMLX

nonisolated final class MLXSmallDocumentSmokeTests: XCTestCase {
  func testInstalledModelReadsDocumentEnding() async throws {
    try await withInstalledModel { runtime, model, root, traceURL in
      try await Self.verifyEnding(runtime: runtime, model: model, root: root, traceURL: traceURL)
    }
  }

  func testInstalledModelGeneratesBeyondDiagnosticContextLength() async throws {
    guard MLXDebugTraceStore.isEnabled else {
      throw XCTSkip("Set SUMIKA_DEBUG_TRACE=1 to verify measured prompt tokens and cache reuse.")
    }
    try await withInstalledModel { runtime, model, _, traceURL in
      try await Self.verifyLongConversation(runtime: runtime, model: model, traceURL: traceURL)
    }
  }

  func testInstalledModelResumesRecordedToolResults() async throws {
    guard
      let path = ProcessInfo.processInfo.environment["SUMIKA_DOCUMENT_SMOKE_SESSION_PATH"]
    else {
      throw XCTSkip("Set SUMIKA_DOCUMENT_SMOKE_SESSION_PATH to replay a saved tool continuation.")
    }
    let document = try WorkspacePersistenceCoding.makeDecoder().decode(
      WorkspaceSessionDocument.self, from: Data(contentsOf: URL(filePath: path)))
    let session = document.session
    let turn = try XCTUnwrap(session.turns.last)
    XCTAssertFalse(session.toolCalls.isEmpty)
    try await withInstalledModel { runtime, model, _, _ in
      XCTAssertEqual(model.id, session.selectedModelID)
      let registry = ToolExecutorRegistry.codingAgent.toolRegistry
      let transcript = ChatModelContextBuilder().transcript(
        from: session, includingTurnID: turn.id,
        supportsHistoricalReasoningPreservation: model.supportsHistoricalReasoningPreservation)
      let plan = ChatRuntimePromptPlan(
        stableInstructions: ToolPromptPolicy().systemPrompt(
          basePrompt: session.systemPrompt, mode: .afterToolResultCanContinue,
          toolRegistry: registry, toolCallingPolicy: model.toolCallingPolicy),
        toolContext: ChatRuntimeToolContext(registry: registry))
      let stream = try await runtime.streamReply(
        for: transcript, attachments: [], promptPlan: plan,
        settings: session.generationSettings, interactionMode: session.interactionMode)
      var visibleCharacters = 0
      var toolCalls = 0
      for try await event in stream {
        switch event {
        case .chunk(let text): visibleCharacters += text.count
        case .toolCall: toolCalls += 1
        case .outputLimitReached: XCTFail("Recorded tool continuation reached its output limit.")
        case .thinkingChunk, .thinkingCompleted, .completed: break
        }
      }
      XCTAssertTrue(visibleCharacters > 0 || toolCalls > 0)
      print(
        "RECORDED TOOL SMOKE: priorTools=\(session.toolCalls.count), newToolCalls=\(toolCalls), visibleCharacters=\(visibleCharacters)"
      )
    }
  }

  private func withInstalledModel(
    _ operation: (MLXChatRuntime, ManagedModel, URL, URL) async throws -> Void
  ) async throws {
    guard let modelID = ProcessInfo.processInfo.environment["SUMIKA_DOCUMENT_SMOKE_MODEL_ID"] else {
      throw XCTSkip(
        "Set SUMIKA_DOCUMENT_SMOKE_MODEL_ID to run an installed-model document smoke test.")
    }
    let model = try XCTUnwrap(ManagedModelCatalog.model(id: modelID))
    let library = Bundle(for: Self.self).resourceURL?
      .appending(path: "mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib")
    guard let library, FileManager.default.fileExists(atPath: library.path(percentEncoded: false))
    else {
      throw XCTSkip("MLX default.metallib is unavailable in the test bundle.")
    }
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
    let tracer = MLXDebugTraceStore(fileURL: traceURL, isEnabled: { true })
    let runtime = MLXChatRuntime(debugTraceStore: tracer)
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
      let metadata = TurnTraceMetadata(turnID: UUID(), generationID: UUID(), tracer: tracer)
      try await TurnTraceContext.$current.withValue(metadata) {
        try await operation(runtime, model, root, traceURL)
      }
      await runtime.unload()
    } catch {
      await runtime.unload()
      throw error
    }
  }

  private static func verifyLongConversation(
    runtime: MLXChatRuntime, model: ManagedModel, traceURL: URL
  ) async throws {
    let recommended = ModelSettingsResolver.recommendedSettings(for: model, generationConfig: nil)
    var settings = recommended.modeSettings.chat.generationSettings
    settings.temperature = 0
    settings.reasoningSelection = .off
    let plan = ChatRuntimePromptPlan(
      stableInstructions: "Follow the user's requested response format.")
    let archive = String(repeating: "oak birch cedar maple pine elm ash fir.\n", count: 2_048)
    var entries = [
      try ModelFacingPromptRenderer.userPromptEntry(
        prompt: "Reference archive:\n\(archive)\nAcknowledge receipt. Reply only READY.")
    ]
    let first = try await reply(runtime: runtime, entries: entries, plan: plan, settings: settings)
    try verifyLongPrefill(traceURL: traceURL, settings: settings, label: "cold")
    entries.append(try ModelFacingPromptRenderer.assistantOutputEntry(content: first))
    entries.append(
      try ModelFacingPromptRenderer.userPromptEntry(
        prompt: "Confirm receipt again. Reply only READY."))
    _ = try await reply(runtime: runtime, entries: entries, plan: plan, settings: settings)
    try verifyLongPrefill(traceURL: traceURL, settings: settings, label: "warm", expectsReuse: true)

    await runtime.clearContext()
    let rawRequest = RawToolCallRequest(
      workspaceID: UUID(), sessionID: UUID(), toolName: .readFile,
      arguments: ["path": .string("receipt.txt")])
    let request = ToolCallRequestValidator().validate(
      rawRequest, registry: ToolExecutorRegistry.codingAgent.toolRegistry)
    let toolEntries = [
      entries[0],
      try ModelFacingPromptRenderer.assistantOutputEntry(
        content: ToolCallModelMessage(rawRequest: rawRequest).modelContextContent),
      try ModelFacingPromptRenderer.toolResultEntry(
        toolResult: ToolResultModelMessage(
          callID: rawRequest.id, toolName: .readFile,
          payload: .readFile(
            .legacySuccess(
              path: WorkspaceRelativePath(rawValue: "receipt.txt"),
              content: ToolTextOutput(text: "Archive received. Reply only READY.")))),
        request: request, originalUserRequest: nil),
    ]
    _ = try await reply(
      runtime: runtime, entries: toolEntries, plan: plan, settings: settings, mode: .agent)
    try verifyLongPrefill(traceURL: traceURL, settings: settings, label: "tool_result")
  }

  private static func reply(
    runtime: MLXChatRuntime, entries: [ModelContextEntry], plan: ChatRuntimePromptPlan,
    settings: ChatGenerationSettings, mode: WorkspaceInteractionMode = .chat
  ) async throws -> String {
    let metadata = TurnTraceContext.current.map {
      TurnTraceMetadata(
        turnID: $0.turnID, generationID: UUID(), tracer: $0.tracer, interactionMode: mode)
    }
    let stream = try await TurnTraceContext.$current.withValue(metadata) {
      try await runtime.streamReply(
        for: ModelPromptProjection(entries: entries), attachments: [],
        promptPlan: plan, settings: settings, interactionMode: mode)
    }
    var output = ""
    var completed = false
    for try await event in stream {
      switch event {
      case .chunk(let text): output += text
      case .completed: completed = true
      case .outputLimitReached: XCTFail("The short smoke response exhausted its output allowance.")
      case .toolCall: XCTFail("The smoke response must answer without requesting another tool.")
      case .thinkingChunk, .thinkingCompleted: break
      }
    }
    XCTAssertTrue(completed)
    XCTAssertFalse(output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    return output
  }

  private static func verifyLongPrefill(
    traceURL: URL, settings: ChatGenerationSettings, label: String, expectsReuse: Bool = false
  ) throws {
    let records = try traceRecords(at: traceURL)
    let request = try XCTUnwrap(records.last { $0["kind"] as? String == "mlx_request" })
    let generationID = try XCTUnwrap(request["id"] as? String)
    let prefill = try XCTUnwrap(
      records.last {
        $0["generationID"] as? String == generationID && $0["phase"] as? String == "runtime_prefill"
      })
    let fullTokens = try XCTUnwrap(prefill["fullPromptTokens"] as? Int)
    XCTAssertGreaterThan(fullTokens, 16_384)
    XCTAssertEqual(request["contextTokenLimit"] as? Int, 16_384)
    let recordedSettings = try XCTUnwrap(request["settings"] as? [String: Any])
    XCTAssertEqual(recordedSettings["maxTokens"] as? Int, settings.maxTokens)
    let reused = prefill["reusedPromptTokens"] as? Int ?? 0
    if expectsReuse { XCTAssertGreaterThan(reused, 0) }
    print(
      "CONVERSATION SMOKE \(label): promptTokens=\(fullTokens), reused=\(reused), maxTokens=\(settings.maxTokens)"
    )
  }

  private static func traceRecords(at url: URL) throws -> [[String: Any]] {
    try String(contentsOf: url, encoding: .utf8).split(separator: "\n").compactMap {
      try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
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
    let records = try traceRecords(at: traceURL)
    if let prefill = records.last(where: { $0["phase"] as? String == "runtime_prefill" }),
      let tokens = prefill["fullPromptTokens"] as? Int
    {
      print("DOCUMENT SMOKE measured prompt tokens: \(tokens)")
    }
    XCTAssertTrue(
      correct, "The response must include both facts from the document ending: \(output)")
    XCTAssertEqual(settings, savedSettings)
  }
}
