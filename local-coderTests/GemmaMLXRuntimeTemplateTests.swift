import Foundation
import LocalCoderCore
import MLXLMCommon
import Testing

@testable import local_coder

@Suite
struct GemmaMLXRuntimeTemplateTests {
  @Test
  func imageInputsUseAttachmentFileURLs() throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appending(
        path: "local-coder-runtime-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    let url = directoryURL.appending(path: "screenshot.png", directoryHint: .notDirectory)
    let data = Data([0x89, 0x50, 0x4e, 0x47])
    try data.write(to: url)
    let store = ChatAttachmentStore(baseURL: directoryURL.appending(path: "attachments"))
    let id = AttachmentID()
    let storedURL = try store.storeFile(from: url, id: id, displayName: "screenshot.png")
    let attachment = ChatAttachment(
      id: id,
      displayName: "screenshot.png",
      payload: .image(
        ImageAttachmentPayload(
          mimeType: "image/png",
          byteSize: data.count,
          contentSHA256: ChatAttachmentStore.contentSHA256(for: data)
        )
      )
    )

    let images = try GemmaMLXRuntime.imageInputs(from: [attachment], attachmentStore: store)

    #expect(images.count == 1)
    guard case .url(let imageURL) = try #require(images.first) else {
      Issue.record("Expected URL-backed image input.")
      return
    }
    #expect(imageURL.lastPathComponent == storedURL.lastPathComponent)
    #expect(try Data(contentsOf: imageURL) == data)
  }

  @Test
  func imageInputBoundaryDisablesCacheEligibility() throws {
    let decision = GemmaMLXRuntime.disabledCacheDecision(
      cachedPrefix: [
        GemmaMessageSnapshot(role: "user", content: "previous"),
        GemmaMessageSnapshot(role: "assistant", content: "answer"),
      ],
      currentHistory: [
        GemmaMessageSnapshot(role: "user", content: "previous"),
        GemmaMessageSnapshot(role: "assistant", content: "answer"),
      ],
      currentSettings: .codingDefault,
      projectionMode: .compactedHistoryForLaterTurns,
      currentNativeToolSchemaHash: "none",
      cacheEligibility: .disabled(reason: .imageInputBoundary)
    )

    #expect(decision.shouldReuse == false)
    #expect(decision.trace.cacheEligibility == "disabled")
    #expect(decision.trace.cacheEligibilityReason == "image_input_boundary")
    #expect(decision.trace.cacheMode == .invalidatedImageInputBoundary)
    #expect(decision.trace.cacheReason == .invalidatedImageInputBoundary)
  }

  @Test
  func templateMessagesUseFrozenTranscriptContent() throws {
    let callID = UUID()
    let transcript = ModelContextSnapshot(
      entries: [
        try ModelFacingPromptRenderer.userPromptEntry(prompt: "create index.htm"),
        try ModelFacingPromptRenderer.assistantOutputEntry(
          content: writeFileToolCall(
            callID: callID,
            arguments: [
              "path": .string("index.htm"),
              "content": .string("<html></html>"),
            ]
          ).modelContextContent
        ),
        try ModelFacingPromptRenderer.toolResultEntry(
          toolResult: ToolResultModelMessage(
            callID: callID,
            toolName: .writeFile,
            payload: .writeFile(
              .success(path: WorkspaceRelativePath(rawValue: "index.htm"), bytesWritten: 13))
          ),
          request: toolRequest(
            callID: callID,
            toolName: .writeFile,
            arguments: [
              "path": .string("index.htm"),
              "content": .string("<html></html>"),
            ]
          )
        ),
        try ModelFacingPromptRenderer.userPromptEntry(
          prompt: "change the background color to green",
          systemContext: ["Use concise coding steps."]
        ),
      ]
    )

    let rendered = try GemmaMLXRuntime.templateMessages(
      from: transcript,
      attachments: [],
      systemPrompt: "This runtime argument must not rewrite frozen content."
    )

    #expect(rendered.map(\.role) == [.user, .assistant, .user])
    #expect(!rendered[0].content.contains("System instructions:"))
    #expect(rendered[2].content.contains("System instructions:"))
    #expect(rendered[2].content.contains("Use concise coding steps."))
    #expect(!rendered[2].content.contains("This runtime argument must not rewrite"))
    #expect(rendered[1].content.contains("Tool call write_file requested."))
    #expect(rendered[1].content.contains("Tool receipt: write_file"))
    #expect(rendered[1].content.contains("Summary:"))
    #expect(rendered[1].content.contains("Wrote 13 bytes to index.htm."))
    #expect(rendered[1].content.contains("<observation") == false)
    #expect(!rendered.contains { $0.role == .system })
  }

  @Test
  func generationHistoryUsesFrozenSystemPromptSnapshot() throws {
    let callID = UUID()
    let entries = [
      try ModelFacingPromptRenderer.userPromptEntry(
        prompt: "create index.htm",
        systemContext: ["Use concise coding steps."]
      ),
      try ModelFacingPromptRenderer.assistantOutputEntry(
        content: writeFileToolCall(
          callID: callID,
          arguments: ["path": .string("index.htm")]
        ).modelContextContent
      ),
      try ModelFacingPromptRenderer.toolResultEntry(
        toolResult: ToolResultModelMessage(
          callID: callID,
          toolName: .writeFile,
          payload: .writeFile(
            .success(path: WorkspaceRelativePath(rawValue: "index.htm"), bytesWritten: 13))
        ),
        request: toolRequest(
          callID: callID,
          toolName: .writeFile,
          arguments: [
            "path": .string("index.htm"),
            "content": .string("<html></html>"),
          ]
        )
      ),
    ]

    let history = try GemmaMLXRuntime.generationHistoryMessages(
      from: try projectedEntries(from: entries)[...]
    )

    #expect(history.map(\.role) == [.user, .assistant])
    #expect(history[0].content.contains("System instructions:"))
    #expect(history[0].content.contains("Use concise coding steps."))
    #expect(!history[0].content.contains("No tools may run now."))
    #expect(!history.contains { $0.role == .system })
  }

  @Test
  func renderedHistoryDoesNotRewriteFirstUserWhenToolPromptModeChanges() throws {
    let initialUser = try ModelFacingPromptRenderer.userPromptEntry(
      prompt: "create index.htm",
      systemContext: ["When tools are available, use them."]
    )
    let initialRendered = try GemmaMLXRuntime.templateMessages(
      from: ModelContextSnapshot(entries: [initialUser]),
      attachments: [],
      systemPrompt: "When tools are available, use them."
    )
    let entries = [
      initialUser,
      try ModelFacingPromptRenderer.assistantOutputEntry(
        content: "Tool call write_file requested."),
      try ModelFacingPromptRenderer.userPromptEntry(
        prompt: "Tool write_file completed with status success.",
        systemContext: ["No more tools may run in this response."]
      ),
      try ModelFacingPromptRenderer.assistantOutputEntry(content: "Done."),
    ]

    let history = try GemmaMLXRuntime.generationHistoryMessages(
      from: try projectedEntries(from: entries)[...]
    )

    #expect(history.map(\.role) == [.user, .assistant, .user, .assistant])
    #expect(history[0].content == initialRendered[0].content)
    #expect(history[2].content.contains("No more tools may run in this response."))
    #expect(!history[0].content.contains("No more tools may run in this response."))
  }

  @Test
  func templateMessagesPreserveFocusedFileSystemContextInsideUserMessage() throws {
    let transcript = ModelContextSnapshot(
      entries: [
        try ModelFacingPromptRenderer.userPromptEntry(
          prompt: "change the background color to green",
          systemContext: [
            "Use concise coding steps.",
            """
            Current focused file: index.htm
            Source: previous write_file
            Known content excerpt:
            <html><body><table><tr><td>Movie</td></tr></table></body></html>
            Explicit file paths in the user request or tool call take precedence.
            """,
          ]
        )
      ]
    )

    let rendered = try GemmaMLXRuntime.templateMessages(
      from: transcript,
      attachments: [],
      systemPrompt: "A later runtime argument must not rewrite frozen content."
    )

    #expect(rendered.map(\.role) == [.user])
    #expect(rendered[0].content.contains("Use concise coding steps."))
    #expect(rendered[0].content.contains("Current focused file: index.htm"))
    #expect(rendered[0].content.contains("<html><body><table>"))
    #expect(rendered[0].content.contains("User request:"))
    #expect(rendered[0].content.contains("change the background color to green"))
  }

  @Test
  func generationPromptPreservesFocusedFileSystemContextOnFirstTurn() throws {
    let entries = [
      try ModelFacingPromptRenderer.userPromptEntry(
        prompt: "explain this",
        systemContext: [
          "Use concise coding steps.",
          """
          Current focused file: index.htm
          Source: previous read_file
          Known content excerpt:
          <h1>Dashboard</h1>
          Explicit file paths in the user request or tool call take precedence.
          """,
        ]
      )
    ]
    let (history, prompt) = try generationHistoryAndPrompt(from: entries)

    #expect(history.isEmpty)
    #expect(prompt.content.contains("Use concise coding steps."))
    #expect(prompt.content.contains("Current focused file: index.htm"))
    #expect(prompt.content.contains("<h1>Dashboard</h1>"))
    #expect(prompt.content.contains("User request:"))
    #expect(prompt.content.contains("explain this"))
  }

  @Test
  func currentPromptContextDoesNotRewriteHistoricalUserMessage() throws {
    let initialUser = try ModelFacingPromptRenderer.userPromptEntry(
      prompt: "summarize the current page",
      systemContext: ["Use concise coding steps."]
    )
    let initialRendered = try GemmaMLXRuntime.templateMessages(
      from: ModelContextSnapshot(entries: [initialUser]),
      attachments: [],
      systemPrompt: "Use concise coding steps."
    )
    let entries = [
      initialUser,
      try ModelFacingPromptRenderer.assistantOutputEntry(content: "The page has a small table."),
      try ModelFacingPromptRenderer.userPromptEntry(
        prompt: "change the heading",
        systemContext: [
          "No more tools may run in this response.",
          """
          Current focused file: robots.html
          Source: previous read_file
          Known content excerpt:
          <table><tr><td>Robot</td></tr></table>
          Explicit file paths in the user request or tool call take precedence.
          """,
        ]
      ),
    ]
    let (history, prompt) = try generationHistoryAndPrompt(from: entries)

    #expect(history.map(\.role) == [.user, .assistant])
    #expect(history[0].content == initialRendered[0].content)
    #expect(!history[0].content.contains("Current focused file: robots.html"))
    #expect(!history[0].content.contains("No more tools may run in this response."))
    #expect(prompt.content.contains("No more tools may run in this response."))
    #expect(prompt.content.contains("Current focused file: robots.html"))
    #expect(prompt.content.contains("<table><tr><td>Robot</td></tr></table>"))
    #expect(prompt.content.contains("change the heading"))
  }

  @Test
  func templateMessagesDoNotTeachGemmaInternalInvalidToolActions() throws {
    let callID = UUID()
    let turnID = UUID()
    let transcript = ModelContextSnapshot(
      entries: [
        try ModelFacingPromptRenderer.userPromptEntry(
          turnID: turnID,
          prompt: "change the table heading"
        ),
        try ModelFacingPromptRenderer.toolResultEntry(
          turnID: turnID,
          toolResult: ToolResultModelMessage(
            callID: callID,
            toolName: .invalid,
            payload: .invalidTool(
              InvalidToolResult(
                originalName: "edit_file",
                reason: .parserError("Assistant described a tool call without an action block.")
              ))
          ),
          request: ToolCallRequest.invalid(
            raw: RawToolCallRequest(
              id: callID,
              workspaceID: UUID(),
              sessionID: UUID(),
              toolName: .invalid
            ),
            input: InvalidToolInput(
              originalName: "edit_file",
              rawArguments: [:],
              reason: .parserError("Assistant described a tool call without an action block.")
            )
          )
        ),
      ]
    )

    let rendered = try GemmaMLXRuntime.templateMessages(
      from: transcript,
      attachments: [],
      systemPrompt: "Use concise coding steps."
    )

    #expect(rendered.map(\.role) == [.user])
    #expect(!rendered.contains { $0.content.contains("<action name=\"invalid\">") })
    #expect(rendered[0].content.contains("The tool call was invalid"))
  }

  @Test
  func renderedContextSignatureIsDeterministicForSameHistoryAndSettings() {
    let settings = ChatGenerationSettings.codingDefault
    let history = GemmaMLXRuntime.messageSnapshot(from: [
      .user("hello"),
      .assistant("hi"),
    ])

    let first = GemmaMLXRuntime.renderedContextSignature(for: history, settings: settings)
    let second = GemmaMLXRuntime.renderedContextSignature(for: history, settings: settings)

    #expect(first == second)
    #expect(first.rendererVersion == GemmaMLXRuntime.gemmaRendererVersion)
    #expect(first.traceValue == second.traceValue)
  }

  @Test
  func renderedContextSignatureChangesWhenRenderedHistoryChanges() {
    let settings = ChatGenerationSettings.codingDefault
    let history = GemmaMLXRuntime.messageSnapshot(from: [
      .user("hello"),
      .assistant("hi"),
    ])
    let changedHistory = GemmaMLXRuntime.messageSnapshot(from: [
      .user("hello"),
      .assistant("different"),
    ])

    let first = GemmaMLXRuntime.renderedContextSignature(for: history, settings: settings)
    let second = GemmaMLXRuntime.renderedContextSignature(
      for: changedHistory,
      settings: settings
    )

    #expect(first != second)
    #expect(first.renderedHistoryHash != second.renderedHistoryHash)
    #expect(first.generationSettingsHash == second.generationSettingsHash)
    #expect(first.nativeToolSchemaHash == second.nativeToolSchemaHash)
  }

  @Test
  func renderedContextSignatureChangesWhenGenerationSettingsChange() {
    let history = GemmaMLXRuntime.messageSnapshot(from: [
      .user("hello"),
      .assistant("hi"),
    ])
    var changedSettings = ChatGenerationSettings.codingDefault
    changedSettings.maxTokens = 128

    let first = GemmaMLXRuntime.renderedContextSignature(
      for: history,
      settings: .codingDefault
    )
    let second = GemmaMLXRuntime.renderedContextSignature(
      for: history,
      settings: changedSettings
    )

    #expect(first != second)
    #expect(first.renderedHistoryHash == second.renderedHistoryHash)
    #expect(first.generationSettingsHash != second.generationSettingsHash)
    #expect(first.nativeToolSchemaHash == second.nativeToolSchemaHash)
  }

  @Test
  func renderedContextSignatureChangesWhenMaxKVSizeChanges() {
    let history = GemmaMLXRuntime.messageSnapshot(from: [
      .user("hello"),
      .assistant("hi"),
    ])
    var changedSettings = ChatGenerationSettings.codingDefault
    changedSettings.maxKVSize = 16_384

    let first = GemmaMLXRuntime.renderedContextSignature(
      for: history,
      settings: .codingDefault
    )
    let second = GemmaMLXRuntime.renderedContextSignature(
      for: history,
      settings: changedSettings
    )

    #expect(first != second)
    #expect(first.renderedHistoryHash == second.renderedHistoryHash)
    #expect(first.generationSettingsHash != second.generationSettingsHash)
    #expect(first.nativeToolSchemaHash == second.nativeToolSchemaHash)
  }

  @Test
  func renderedContextSignatureChangesWhenNativeToolSchemaChanges() {
    let history = GemmaMLXRuntime.messageSnapshot(from: [
      .user("hello"),
      .assistant("hi"),
    ])
    let readOnlyToolSchemaHash = GemmaMLXRuntime.nativeToolSchemaSignature(
      for: ToolExecutorRegistry.readOnly.toolRegistry.tools
    )
    let codingToolSchemaHash = GemmaMLXRuntime.nativeToolSchemaSignature(
      for: ToolExecutorRegistry.codingAgent.toolRegistry.tools
    )

    let first = GemmaMLXRuntime.renderedContextSignature(
      for: history,
      settings: .codingDefault,
      nativeToolSchemaHash: readOnlyToolSchemaHash
    )
    let second = GemmaMLXRuntime.renderedContextSignature(
      for: history,
      settings: .codingDefault,
      nativeToolSchemaHash: codingToolSchemaHash
    )

    #expect(first != second)
    #expect(first.renderedHistoryHash == second.renderedHistoryHash)
    #expect(first.generationSettingsHash == second.generationSettingsHash)
    #expect(first.nativeToolSchemaHash != second.nativeToolSchemaHash)
  }

  @Test
  func renderedContextSignatureChangesWhenProjectionModeChanges() {
    let settings = ChatGenerationSettings.codingDefault
    let history = GemmaMLXRuntime.messageSnapshot(from: [
      .user("hello"),
      .assistant("hi"),
    ])

    let full = GemmaMLXRuntime.renderedContextSignature(
      for: history,
      settings: settings,
      projectionMode: .fullHistory
    )
    let compacted = GemmaMLXRuntime.renderedContextSignature(
      for: history,
      settings: settings,
      projectionMode: .compactedHistoryForLaterTurns
    )

    #expect(full != compacted)
    #expect(full.projectionMode == .fullHistory)
    #expect(compacted.projectionMode == .compactedHistoryForLaterTurns)
    #expect(full.renderedHistoryHash == compacted.renderedHistoryHash)
    #expect(full.generationSettingsHash == compacted.generationSettingsHash)
  }

  @Test
  func cacheDecisionInvalidatesWhenRendererVersionChanges() {
    let settings = ChatGenerationSettings.codingDefault
    let prefix = GemmaMLXRuntime.messageSnapshot(from: [
      .user("hello"),
      .assistant("hi"),
    ])
    let cachedSignature = GemmaMLXRuntime.renderedContextSignature(
      for: prefix,
      settings: settings,
      rendererVersion: GemmaMLXRuntime.gemmaRendererVersion - 1
    )

    let decision = GemmaMLXRuntime.cacheDecision(
      cachedPrefix: prefix,
      cachedSettings: settings,
      cachedContextSignature: cachedSignature,
      cachedState: .clean,
      currentHistory: prefix,
      currentSettings: settings
    )

    #expect(!decision.shouldReuse)
    #expect(decision.trace.cacheMode == .invalidatedSignatureMismatch)
    #expect(decision.trace.cacheReason == .invalidatedRendererVersionChanged)
    #expect(decision.trace.mismatchReason == "rendered_context_signature_changed")
    #expect(decision.trace.contextSignature != decision.trace.previousContextSignature)
  }

  @Test
  func cacheDecisionReportsNewSessionWhenNoCacheExists() {
    let settings = ChatGenerationSettings.codingDefault
    let history = GemmaMLXRuntime.messageSnapshot(from: [
      .user("hello")
    ])

    let decision = GemmaMLXRuntime.cacheDecision(
      cachedPrefix: nil,
      cachedSettings: nil,
      cachedState: nil,
      currentHistory: history,
      currentSettings: settings
    )

    #expect(!decision.shouldReuse)
    #expect(decision.trace.cacheMode == .newSessionHistory)
    #expect(decision.trace.cacheReason == .newSessionNoCache)
    #expect(decision.trace.mismatchReason == nil)
  }

  @Test
  func cacheDecisionReportsRenderedContextSignatureChangeSeparatelyFromRendererVersion() {
    let settings = ChatGenerationSettings.codingDefault
    let prefix = GemmaMLXRuntime.messageSnapshot(from: [
      .user("hello"),
      .assistant("hi"),
    ])
    let cachedSignature = GemmaRenderedContextSignature(
      rendererVersion: GemmaMLXRuntime.gemmaRendererVersion,
      projectionMode: .fullHistory,
      renderedHistoryHash: "different-history",
      generationSettingsHash: GemmaMLXRuntime.renderedContextSignature(
        for: prefix,
        settings: settings
      ).generationSettingsHash,
      nativeToolSchemaHash: GemmaMLXRuntime.nativeToolSchemaSignature(from: nil)
    )

    let decision = GemmaMLXRuntime.cacheDecision(
      cachedPrefix: prefix,
      cachedSettings: settings,
      cachedContextSignature: cachedSignature,
      cachedState: .clean,
      currentHistory: prefix,
      currentSettings: settings
    )

    #expect(!decision.shouldReuse)
    #expect(decision.trace.cacheMode == .invalidatedSignatureMismatch)
    #expect(decision.trace.cacheReason == .invalidatedRenderedContextChanged)
    #expect(decision.trace.mismatchReason == "rendered_context_signature_changed")
  }

  @Test
  func cacheDecisionInvalidatesWhenProjectionModeChanges() {
    let settings = ChatGenerationSettings.codingDefault
    let prefix = GemmaMLXRuntime.messageSnapshot(from: [
      .user("hello"),
      .assistant("hi"),
    ])
    let cachedSignature = GemmaMLXRuntime.renderedContextSignature(
      for: prefix,
      settings: settings,
      projectionMode: .fullHistory
    )

    let decision = GemmaMLXRuntime.cacheDecision(
      cachedPrefix: prefix,
      cachedSettings: settings,
      cachedContextSignature: cachedSignature,
      cachedState: .clean,
      currentHistory: prefix,
      currentSettings: settings,
      projectionMode: .compactedHistoryForLaterTurns
    )

    #expect(!decision.shouldReuse)
    #expect(decision.trace.cacheMode == .invalidatedSignatureMismatch)
    #expect(decision.trace.cacheReason == .invalidatedRenderedContextChanged)
    #expect(decision.trace.mismatchReason == "rendered_context_signature_changed")
    #expect(decision.trace.contextSignature != decision.trace.previousContextSignature)
  }

  @Test
  func generationOwnershipBeginsMonotonicGenerations() {
    var ownership = GemmaGenerationOwnership()

    let first = ownership.beginGeneration()
    let second = ownership.beginGeneration()

    #expect(first.rawValue == 1)
    #expect(second.rawValue == 2)
    #expect(ownership.activeGenerationID == second)
  }

  @Test
  func generationOwnershipCompletesOnlyCurrentGeneration() {
    var ownership = GemmaGenerationOwnership()
    let first = ownership.beginGeneration()
    let second = ownership.beginGeneration()

    let staleCompletionAccepted = ownership.completeIfCurrent(first)
    #expect(ownership.activeGenerationID == second)
    let currentCompletionAccepted = ownership.completeIfCurrent(second)
    #expect(ownership.activeGenerationID == nil)
    let repeatedCompletionAccepted = ownership.completeIfCurrent(second)

    #expect(!staleCompletionAccepted)
    #expect(currentCompletionAccepted)
    #expect(!repeatedCompletionAccepted)
  }

  @Test
  func generationOwnershipInvalidatesOnlyCurrentGeneration() {
    var ownership = GemmaGenerationOwnership()
    let first = ownership.beginGeneration()
    let second = ownership.beginGeneration()

    let staleInvalidationAccepted = ownership.invalidateIfCurrent(first)
    #expect(ownership.activeGenerationID == second)
    let currentInvalidationAccepted = ownership.invalidateIfCurrent(second)
    #expect(ownership.activeGenerationID == nil)
    let repeatedInvalidationAccepted = ownership.invalidateIfCurrent(second)

    #expect(!staleInvalidationAccepted)
    #expect(currentInvalidationAccepted)
    #expect(!repeatedInvalidationAccepted)
  }

  @Test
  func generationOwnershipInvalidatesActiveGeneration() {
    var ownership = GemmaGenerationOwnership()
    let generationID = ownership.beginGeneration()

    ownership.invalidateActiveGeneration()

    #expect(ownership.activeGenerationID == nil)
    let completionAccepted = ownership.completeIfCurrent(generationID)
    let invalidationAccepted = ownership.invalidateIfCurrent(generationID)

    #expect(!completionAccepted)
    #expect(!invalidationAccepted)
  }

  @Test
  func activeGenerationRegistrySupersedesAndCancelsPreviousTask() async throws {
    var registry = GemmaActiveGenerationRegistry()
    let generationID = GemmaGenerationID(rawValue: 1)
    let task = Task<Void, Never> {
      do {
        try await Task.sleep(for: .seconds(5))
      } catch {}
    }

    registry.register(id: generationID, task: task)

    let supersededGeneration = registry.supersedeActiveGeneration()
    let superseded = try #require(supersededGeneration)
    #expect(superseded.id == generationID)
    #expect(superseded.task.isCancelled)
    #expect(registry.activeGenerationID == nil)

    try await withTestTimeout(.seconds(5)) {
      await superseded.task.value
    }
  }

  @Test
  func activeGenerationRegistryClearsOnlyCurrentGeneration() {
    var registry = GemmaActiveGenerationRegistry()
    let first = GemmaGenerationID(rawValue: 1)
    let second = GemmaGenerationID(rawValue: 2)
    let task = Task<Void, Never> {}

    registry.register(id: first, task: task)

    let staleClearAccepted = registry.clearIfCurrent(second)
    #expect(!staleClearAccepted)
    #expect(registry.activeGenerationID == first)
    let currentClearAccepted = registry.clearIfCurrent(first)
    #expect(currentClearAccepted)
    #expect(registry.activeGenerationID == nil)
  }

  @Test
  func cachedSessionStateIsReusableOnlyWhenClean() {
    let generationID = GemmaGenerationID(rawValue: 1)

    #expect(GemmaCachedSessionState.clean.isReusable)
    #expect(GemmaCachedSessionState.cleanNativeToolCallBoundary.isReusable)
    #expect(!GemmaCachedSessionState.inFlight(generationID: generationID).isReusable)
    #expect(!GemmaCachedSessionState.dirty(reason: .cancelled).isReusable)
    #expect(GemmaCachedSessionState.clean.invalidationReason == nil)
    #expect(GemmaCachedSessionState.cleanNativeToolCallBoundary.invalidationReason == nil)
    #expect(
      GemmaCachedSessionState.inFlight(generationID: generationID).invalidationReason
        == .interrupted)
    #expect(
      GemmaCachedSessionState.dirty(reason: .runtimeError).invalidationReason == .runtimeError)
  }

  @Test
  func cachedSessionStateTransitionsOnlyForOwningGeneration() {
    let first = GemmaGenerationID(rawValue: 1)
    let second = GemmaGenerationID(rawValue: 2)
    let inFlight = GemmaCachedSessionState.inFlight(generationID: second)

    #expect(inFlight.completing(generationID: first) == nil)
    #expect(inFlight.completingNativeToolCallBoundary(generationID: first) == nil)
    #expect(inFlight.invalidating(generationID: first, reason: .cancelled) == nil)
    #expect(inFlight.completing(generationID: second) == .clean)
    #expect(
      inFlight.completingNativeToolCallBoundary(generationID: second)
        == .cleanNativeToolCallBoundary)
    #expect(
      inFlight.invalidating(generationID: second, reason: .downstreamTerminated)
        == .dirty(reason: .downstreamTerminated))
  }

  @Test
  func cacheDecisionReusesOnlyExactRenderedPrefix() {
    let settings = ChatGenerationSettings.codingDefault
    let prefix = GemmaMLXRuntime.messageSnapshot(from: [
      .user("hello"),
      .assistant("hi"),
    ])

    let decision = GemmaMLXRuntime.cacheDecision(
      cachedPrefix: prefix,
      cachedSettings: settings,
      cachedState: .clean,
      currentHistory: prefix,
      currentSettings: settings
    )

    #expect(decision.shouldReuse)
    #expect(decision.trace.cacheMode == .sessionReused)
    #expect(decision.trace.cacheReason == .sessionReused)
    #expect(decision.trace.appendOnly)
    #expect(decision.trace.reusedMessageCount == 2)
    #expect(decision.trace.appendedMessageCount == 0)
  }

  @Test
  func cacheDecisionReusesExactNativeToolSchemaPrefix() {
    let settings = ChatGenerationSettings.codingDefault
    let prefix = GemmaMLXRuntime.messageSnapshot(from: [
      .user("hello"),
      .assistant("hi"),
    ])
    let toolSchemaHash = GemmaMLXRuntime.nativeToolSchemaSignature(
      for: ToolExecutorRegistry.readOnly.toolRegistry.tools
    )
    let cachedSignature = GemmaMLXRuntime.renderedContextSignature(
      for: prefix,
      settings: settings,
      nativeToolSchemaHash: toolSchemaHash
    )

    let decision = GemmaMLXRuntime.cacheDecision(
      cachedPrefix: prefix,
      cachedSettings: settings,
      cachedContextSignature: cachedSignature,
      cachedState: .clean,
      currentHistory: prefix,
      currentSettings: settings,
      currentNativeToolSchemaHash: toolSchemaHash
    )

    #expect(decision.shouldReuse)
    #expect(decision.trace.cacheMode == .sessionReused)
    #expect(decision.trace.cacheReason == .sessionReused)
  }

  @Test
  func cacheDecisionInvalidatesWhenNativeToolSchemaChanges() {
    let settings = ChatGenerationSettings.codingDefault
    let prefix = GemmaMLXRuntime.messageSnapshot(from: [
      .user("hello"),
      .assistant("hi"),
    ])
    let readOnlyToolSchemaHash = GemmaMLXRuntime.nativeToolSchemaSignature(
      for: ToolExecutorRegistry.readOnly.toolRegistry.tools
    )
    let codingToolSchemaHash = GemmaMLXRuntime.nativeToolSchemaSignature(
      for: ToolExecutorRegistry.codingAgent.toolRegistry.tools
    )
    let cachedSignature = GemmaMLXRuntime.renderedContextSignature(
      for: prefix,
      settings: settings,
      nativeToolSchemaHash: readOnlyToolSchemaHash
    )

    let decision = GemmaMLXRuntime.cacheDecision(
      cachedPrefix: prefix,
      cachedSettings: settings,
      cachedContextSignature: cachedSignature,
      cachedState: .clean,
      currentHistory: prefix,
      currentSettings: settings,
      currentNativeToolSchemaHash: codingToolSchemaHash
    )

    #expect(!decision.shouldReuse)
    #expect(decision.trace.cacheMode == .invalidatedSignatureMismatch)
    #expect(decision.trace.cacheReason == .invalidatedToolSchemaChanged)
    #expect(decision.trace.mismatchReason == "rendered_context_signature_changed")
  }

  @Test
  func cacheDecisionReusesExactNoToolSchemaPrefix() {
    let settings = ChatGenerationSettings.codingDefault
    let prefix = GemmaMLXRuntime.messageSnapshot(from: [
      .user("hello"),
      .assistant("hi"),
    ])
    let cachedSignature = GemmaMLXRuntime.renderedContextSignature(
      for: prefix,
      settings: settings,
      nativeToolSchemaHash: GemmaMLXRuntime.nativeToolSchemaSignature(from: nil)
    )

    let decision = GemmaMLXRuntime.cacheDecision(
      cachedPrefix: prefix,
      cachedSettings: settings,
      cachedContextSignature: cachedSignature,
      cachedState: .clean,
      currentHistory: prefix,
      currentSettings: settings,
      currentNativeToolSchemaHash: GemmaMLXRuntime.nativeToolSchemaSignature(from: nil)
    )

    #expect(decision.shouldReuse)
    #expect(decision.trace.cacheMode == .sessionReused)
    #expect(decision.trace.cacheReason == .sessionReused)
  }

  @Test
  func toolObservationFollowUpUsesCachedPrefixAsHistoryAndObservationAsPrompt() throws {
    let callID = UUID()
    let turnID = UUID()
    let entries = [
      try ModelFacingPromptRenderer.userPromptEntry(
        turnID: turnID,
        prompt: "read README.md",
        systemContext: ["Read-only tools are available."]
      ),
      try ModelFacingPromptRenderer.assistantOutputEntry(
        turnID: turnID,
        content: """
          <action name="read_file">
          <path>README.md</path>
          </action>
          """
      ),
      try ModelFacingPromptRenderer.toolResultEntry(
        turnID: turnID,
        toolResult: ToolResultModelMessage(
          callID: callID,
          toolName: .readFile,
          payload: .readFile(
            .success(
              path: WorkspaceRelativePath(rawValue: "README.md"),
              content: ToolTextOutput(text: "Project overview")
            ))
        ),
        request: toolRequest(
          callID: callID,
          toolName: .readFile,
          arguments: ["path": .string("README.md")]
        ),
        systemContext: ["Read-only tools are available."]
      ),
    ]
    let (history, prompt) = try generationHistoryAndPrompt(from: entries)
    let prefix = GemmaMLXRuntime.messageSnapshot(from: history)
    let decision = GemmaMLXRuntime.cacheDecision(
      cachedPrefix: prefix,
      cachedSettings: .codingDefault,
      cachedState: .clean,
      currentHistory: prefix,
      currentSettings: .codingDefault
    )

    #expect(history.map(\.role) == [.user, .assistant])
    #expect(prompt.role == .user)
    #expect(prompt.content.contains("<observation"))
    #expect(prompt.content.contains("Project overview"))
    #expect(decision.shouldReuse)
    #expect(decision.trace.cacheMode == .sessionReused)
    #expect(decision.trace.cacheReason == .sessionReused)
    #expect(decision.trace.appendedMessageCount == 0)
    #expect(decision.trace.mismatchReason == nil)
  }

  @Test
  func laterUserTurnHistoryCompactsPreviousToolObservationToReceipt() throws {
    let callID = UUID()
    let transcript = ModelContextSnapshot(entries: [
      try ModelFacingPromptRenderer.userPromptEntry(prompt: "read README.md"),
      try ModelFacingPromptRenderer.assistantOutputEntry(
        content: """
          <action name="read_file">
          <path>README.md</path>
          </action>
          """
      ),
      try ModelFacingPromptRenderer.toolResultEntry(
        toolResult: ToolResultModelMessage(
          callID: callID,
          toolName: .readFile,
          payload: .readFile(
            .success(
              path: WorkspaceRelativePath(rawValue: "README.md"),
              content: ToolTextOutput(text: "Project overview")
            ))
        ),
        request: toolRequest(
          callID: callID,
          toolName: .readFile,
          arguments: ["path": .string("README.md")]
        )
      ),
      try ModelFacingPromptRenderer.assistantOutputEntry(content: "README.md is a project file."),
      try ModelFacingPromptRenderer.userPromptEntry(prompt: "what did you read?"),
    ])

    let history = try GemmaMLXRuntime.generationHistoryMessages(from: transcript)

    #expect(history.map(\.role) == [.user, .assistant, .user, .assistant])
    #expect(history[2].content.contains("Tool receipt: read_file"))
    #expect(history[2].content.contains("Summary:"))
    #expect(history[2].content.contains("Project overview"))
    #expect(history[2].content.contains("<observation") == false)
  }

  @Test
  func terminalToolResultFollowUpUsesCachedPrefixAsHistoryAndResultAsPrompt() throws {
    let callID = UUID()
    let turnID = UUID()
    let terminalResult = ToolResultModelMessage(
      callID: callID,
      toolName: .writeFile,
      payload: .writeFile(
        .success(path: WorkspaceRelativePath(rawValue: "movies.html"), bytesWritten: 13))
    )
    let terminalRequest = toolRequest(
      callID: callID,
      toolName: .writeFile,
      arguments: [
        "path": .string("movies.html"),
        "content": .string("<html></html>"),
      ]
    )
    let terminalObservation = ToolResultProjector.project(
      payload: terminalResult.payload,
      request: terminalRequest
    ).observation
    let entries = [
      try ModelFacingPromptRenderer.userPromptEntry(
        turnID: turnID,
        prompt: "create movies.html",
        systemContext: ["Tools are available."]
      ),
      try ModelFacingPromptRenderer.assistantOutputEntry(
        turnID: turnID,
        content: writeFileToolCall(
          callID: callID,
          arguments: [
            "path": .string("movies.html"),
            "content": .string("<html></html>"),
          ]
        ).modelContextContent
      ),
      try ModelFacingPromptRenderer.finalToolResultPromptEntry(
        turnID: turnID,
        terminalToolResult: TerminalToolResultContext(
          callID: callID,
          toolName: terminalResult.toolName,
          status: terminalResult.preview.status,
          content: ToolModelObservationRenderer.render(
            terminalObservation,
            callID: terminalResult.callID
          )
        ),
        followUpInstruction: "Use the preceding tool result to answer the user's request.",
        systemContext: ["No more tools may run in this response."]
      ),
    ]
    let (history, prompt) = try generationHistoryAndPrompt(from: entries)
    let prefix = GemmaMLXRuntime.messageSnapshot(from: history)
    let decision = GemmaMLXRuntime.cacheDecision(
      cachedPrefix: prefix,
      cachedSettings: .codingDefault,
      cachedState: .clean,
      currentHistory: prefix,
      currentSettings: .codingDefault
    )

    #expect(history.map(\.role) == [.user, .assistant])
    #expect(prompt.role == .user)
    #expect(prompt.content.contains("Summary: Wrote 13 bytes to movies.html."))
    #expect(prompt.content.contains("Use the preceding tool result to answer"))
    #expect(prompt.content.contains("No more tools may run in this response."))
    #expect(decision.shouldReuse)
    #expect(decision.trace.cacheMode == .sessionReused)
    #expect(decision.trace.cacheReason == .sessionReused)
    #expect(decision.trace.appendedMessageCount == 0)
    #expect(decision.trace.mismatchReason == nil)
  }

  @Test
  func cacheDecisionReusesCleanAppendOnlyHistoryAsDelta() {
    let settings = ChatGenerationSettings.codingDefault
    let prefix = GemmaMLXRuntime.messageSnapshot(from: [
      .user("hello"),
      .assistant("hi"),
    ])
    let appendedHistory = GemmaMLXRuntime.messageSnapshot(from: [
      .user("hello"),
      .assistant("hi"),
      .user("tool observation"),
    ])

    let decision = GemmaMLXRuntime.cacheDecision(
      cachedPrefix: prefix,
      cachedSettings: settings,
      cachedState: .clean,
      currentHistory: appendedHistory,
      currentSettings: settings
    )

    #expect(decision.shouldReuse)
    #expect(decision.reuseStrategy == .appendHistoryDelta(startIndex: 2))
    #expect(decision.trace.cacheMode == .sessionReused)
    #expect(decision.trace.cacheReason == .appendOnlyDeltaReused)
    #expect(decision.trace.appendOnly)
    #expect(decision.trace.reusedMessageCount == 2)
    #expect(decision.trace.appendedMessageCount == 1)
    #expect(decision.trace.mismatchReason == nil)
    #expect(decision.trace.firstMismatchIndex == nil)
  }

  @Test
  func cacheDecisionReusesNativeToolCallBoundaryFollowUpDelta() {
    let settings = ChatGenerationSettings.codingDefault
    let nativeToolCall = ChatRuntimeToolCall(
      name: "read_file",
      arguments: ["path": .string("README.md")]
    )
    let nativeBoundary = NativeToolCallBoundaryRenderer.renderGemma4(nativeToolCall)
    let prefix = GemmaMLXRuntime.messageSnapshot(from: [
      .user("read the file"),
      .assistant(nativeBoundary),
    ])
    let appendedHistory = GemmaMLXRuntime.messageSnapshot(from: [
      .user("read the file"),
      .assistant(nativeBoundary),
      .user("Tool observation:\n1: project notes"),
    ])

    let decision = GemmaMLXRuntime.cacheDecision(
      cachedPrefix: prefix,
      cachedSettings: settings,
      cachedState: .clean,
      currentHistory: appendedHistory,
      currentSettings: settings
    )

    #expect(decision.shouldReuse)
    #expect(decision.reuseStrategy == .appendHistoryDelta(startIndex: 2))
    #expect(decision.trace.cacheMode == .sessionReused)
    #expect(decision.trace.cacheReason == .appendOnlyDeltaReused)
  }

  @Test
  func cacheDecisionTracesSameTurnNativeToolCallBoundaryReuseAsAppendOnly() {
    let settings = ChatGenerationSettings.codingDefault
    let nativeToolCall = ChatRuntimeToolCall(
      name: "read_file",
      arguments: ["path": .string("README.md")]
    )
    let nativeBoundary = NativeToolCallBoundaryRenderer.renderGemma4(nativeToolCall)
    let prefix = GemmaMLXRuntime.messageSnapshot(from: [
      .user("read the file"),
      .assistant(nativeBoundary),
    ])

    let decision = GemmaMLXRuntime.cacheDecision(
      cachedPrefix: prefix,
      cachedSettings: settings,
      cachedState: .cleanNativeToolCallBoundary,
      currentHistory: prefix,
      currentSettings: settings
    )

    #expect(decision.shouldReuse)
    #expect(decision.reuseStrategy == .appendHistoryDelta(startIndex: 2))
    #expect(decision.trace.cacheMode == .sessionReused)
    #expect(decision.trace.cacheReason == .appendOnlyDeltaReused)
    #expect(decision.trace.appendOnly)
    #expect(decision.trace.reusedMessageCount == 2)
    #expect(decision.trace.appendedMessageCount == 0)
  }

  @Test
  func cacheDecisionReusesNativeToolCallBoundaryAfterAssistantPreamble() {
    let settings = ChatGenerationSettings.codingDefault
    let nativeToolCall = ChatRuntimeToolCall(
      name: "read_file",
      arguments: ["path": .string("README.md")]
    )
    let nativeBoundary = NativeToolCallBoundaryRenderer.renderGemma4(nativeToolCall)
    let prefix = GemmaMLXRuntime.messageSnapshot(from: [
      .user("read the file"),
      .assistant("I'll inspect that."),
      .assistant(nativeBoundary),
    ])

    let decision = GemmaMLXRuntime.cacheDecision(
      cachedPrefix: prefix,
      cachedSettings: settings,
      cachedState: .cleanNativeToolCallBoundary,
      currentHistory: prefix,
      currentSettings: settings
    )

    #expect(decision.shouldReuse)
    #expect(decision.reuseStrategy == .appendHistoryDelta(startIndex: 3))
    #expect(decision.trace.cacheMode == .sessionReused)
    #expect(decision.trace.cacheReason == .appendOnlyDeltaReused)
    #expect(decision.trace.appendOnly)
    #expect(decision.trace.reusedMessageCount == 3)
    #expect(decision.trace.appendedMessageCount == 0)
  }

  @Test
  func cacheDecisionInvalidatesAppendOnlyHistoryWhenNativeToolSchemaChanges() {
    let settings = ChatGenerationSettings.codingDefault
    let prefix = GemmaMLXRuntime.messageSnapshot(from: [
      .user("hello"),
      .assistant("hi"),
    ])
    let appendedHistory = GemmaMLXRuntime.messageSnapshot(from: [
      .user("hello"),
      .assistant("hi"),
      .user("tool observation"),
    ])
    let readOnlyToolSchemaHash = GemmaMLXRuntime.nativeToolSchemaSignature(
      for: ToolExecutorRegistry.readOnly.toolRegistry.tools
    )
    let codingToolSchemaHash = GemmaMLXRuntime.nativeToolSchemaSignature(
      for: ToolExecutorRegistry.codingAgent.toolRegistry.tools
    )
    let cachedSignature = GemmaMLXRuntime.renderedContextSignature(
      for: prefix,
      settings: settings,
      nativeToolSchemaHash: readOnlyToolSchemaHash
    )

    let decision = GemmaMLXRuntime.cacheDecision(
      cachedPrefix: prefix,
      cachedSettings: settings,
      cachedContextSignature: cachedSignature,
      cachedState: .clean,
      currentHistory: appendedHistory,
      currentSettings: settings,
      currentNativeToolSchemaHash: codingToolSchemaHash
    )

    #expect(!decision.shouldReuse)
    #expect(decision.reuseStrategy == .none)
    #expect(decision.trace.cacheMode == .invalidatedSignatureMismatch)
    #expect(decision.trace.cacheReason == .invalidatedToolSchemaChanged)
    #expect(decision.trace.appendOnly)
    #expect(decision.trace.reusedMessageCount == 2)
    #expect(decision.trace.appendedMessageCount == 1)
    #expect(decision.trace.mismatchReason == "rendered_context_signature_changed")
  }

  @Test
  func cacheDecisionKeepsDirtyAppendOnlyHistoryInvalidated() {
    let settings = ChatGenerationSettings.codingDefault
    let prefix = GemmaMLXRuntime.messageSnapshot(from: [
      .user("hello"),
      .assistant("hi"),
    ])
    let appendedHistory = GemmaMLXRuntime.messageSnapshot(from: [
      .user("hello"),
      .assistant("hi"),
      .user("tool observation"),
    ])

    let decision = GemmaMLXRuntime.cacheDecision(
      cachedPrefix: prefix,
      cachedSettings: settings,
      cachedState: .dirty(reason: .downstreamTerminated),
      currentHistory: appendedHistory,
      currentSettings: settings
    )

    #expect(!decision.shouldReuse)
    #expect(decision.trace.cacheMode == .invalidatedDownstreamTerminated)
    #expect(decision.trace.cacheReason == .invalidatedGenDownstreamTerminated)
    #expect(decision.trace.appendOnly)
    #expect(decision.trace.reusedMessageCount == 2)
    #expect(decision.trace.appendedMessageCount == 1)
    #expect(decision.trace.mismatchReason == nil)
  }

  @Test
  func cacheDecisionReportsNativeToolCallBoundaryInvalidation() {
    let settings = ChatGenerationSettings.codingDefault
    let prefix = GemmaMLXRuntime.messageSnapshot(from: [
      .user("call a native tool")
    ])

    let decision = GemmaMLXRuntime.cacheDecision(
      cachedPrefix: prefix,
      cachedSettings: settings,
      cachedState: .dirty(reason: .nativeToolCallBoundary),
      currentHistory: prefix,
      currentSettings: settings
    )

    #expect(!decision.shouldReuse)
    #expect(decision.reuseStrategy == .none)
    #expect(decision.trace.cacheMode == .invalidatedNativeToolCallBoundary)
    #expect(decision.trace.cacheReason == .invalidatedNativeToolCallBoundary)
    #expect(decision.trace.mismatchReason == nil)
  }

  @Test
  func cacheDecisionInvalidatesWhenRenderedHistoryChanges() {
    let settings = ChatGenerationSettings.codingDefault
    let prefix = GemmaMLXRuntime.messageSnapshot(from: [
      .user("hello"),
      .assistant("hi"),
    ])
    let changedHistory = GemmaMLXRuntime.messageSnapshot(from: [
      .user("hello"),
      .assistant("different"),
    ])

    let decision = GemmaMLXRuntime.cacheDecision(
      cachedPrefix: prefix,
      cachedSettings: settings,
      cachedState: .clean,
      currentHistory: changedHistory,
      currentSettings: settings
    )

    #expect(!decision.shouldReuse)
    #expect(decision.trace.cacheMode == .invalidatedSignatureMismatch)
    #expect(decision.trace.cacheReason == .invalidatedHistoryPrefixMismatch)
    #expect(!decision.trace.appendOnly)
    #expect(decision.trace.mismatchReason == "history_prefix_mismatch")
    #expect(decision.trace.firstMismatchIndex == 1)
  }

  @Test
  func cacheDecisionInvalidatesWhenSettingsChange() {
    var changedSettings = ChatGenerationSettings.codingDefault
    changedSettings.maxTokens = 128
    let prefix = GemmaMLXRuntime.messageSnapshot(from: [
      .user("hello"),
      .assistant("hi"),
    ])

    let decision = GemmaMLXRuntime.cacheDecision(
      cachedPrefix: prefix,
      cachedSettings: .codingDefault,
      cachedState: .clean,
      currentHistory: prefix,
      currentSettings: changedSettings
    )

    #expect(!decision.shouldReuse)
    #expect(decision.trace.cacheMode == .invalidatedSignatureMismatch)
    #expect(decision.trace.cacheReason == .invalidatedSettingsChanged)
    #expect(decision.trace.mismatchReason == "settings_changed")
    #expect(decision.trace.firstMismatchIndex == nil)
  }

  @Test
  func cacheDecisionReportsCurrentPromptContextMismatchSeparatelyFromBasePrompt() {
    let settings = ChatGenerationSettings.codingDefault
    let prefix = [
      GemmaMessageSnapshot(
        role: "user",
        content: """
          System instructions:
          Base prompt.

          Current focused file: robots.html
          Source: previous read_file
          Explicit file paths in the user request or tool call take precedence.

          User request:
          show the file
          """
      ),
      GemmaMessageSnapshot(role: "assistant", content: "hi"),
    ]
    let changedCurrentPromptContext = [
      GemmaMessageSnapshot(
        role: "user",
        content: """
          System instructions:
          Base prompt.

          Current focused file: index.html
          Source: previous read_file
          Explicit file paths in the user request or tool call take precedence.

          User request:
          show the file
          """
      ),
      GemmaMessageSnapshot(role: "assistant", content: "hi"),
    ]

    let decision = GemmaMLXRuntime.cacheDecision(
      cachedPrefix: prefix,
      cachedSettings: settings,
      cachedState: .clean,
      currentHistory: changedCurrentPromptContext,
      currentSettings: settings
    )

    #expect(!decision.shouldReuse)
    #expect(decision.trace.cacheMode == .invalidatedSignatureMismatch)
    #expect(decision.trace.cacheReason == .invalidatedCurrentPromptContextBoundary)
    #expect(decision.trace.mismatchReason == "history_prefix_mismatch")
    #expect(decision.trace.firstMismatchIndex == 0)
    #expect(decision.trace.systemPromptChanged == false)
    #expect(decision.trace.currentPromptContextChanged == true)
  }

  @Test
  func cacheDecisionReportsAttachedFileContextMismatchSeparatelyFromBasePrompt() {
    let settings = ChatGenerationSettings.codingDefault
    let prefix = [
      GemmaMessageSnapshot(
        role: "user",
        content: """
          System instructions:
          Base prompt.

          Attached file: Sources/Foo.swift
          Content hash: hash-1
          Attached content excerpt:
          let value = 1
          Explicit file paths in the user request or tool call take precedence.

          User request:
          explain the attachment
          """
      )
    ]
    let changedAttachedFile = [
      GemmaMessageSnapshot(
        role: "user",
        content: """
          System instructions:
          Base prompt.

          Attached file: Sources/Bar.swift
          Content hash: hash-2
          Attached content excerpt:
          let value = 2
          Explicit file paths in the user request or tool call take precedence.

          User request:
          explain the attachment
          """
      )
    ]

    let decision = GemmaMLXRuntime.cacheDecision(
      cachedPrefix: prefix,
      cachedSettings: settings,
      cachedState: .clean,
      currentHistory: changedAttachedFile,
      currentSettings: settings
    )

    #expect(!decision.shouldReuse)
    #expect(decision.trace.cacheMode == .invalidatedSignatureMismatch)
    #expect(decision.trace.cacheReason == .invalidatedCurrentPromptContextBoundary)
    #expect(decision.trace.mismatchReason == "history_prefix_mismatch")
    #expect(decision.trace.firstMismatchIndex == 0)
    #expect(decision.trace.systemPromptChanged == false)
    #expect(decision.trace.currentPromptContextChanged == true)
  }

  @Test
  func cacheDecisionReportsBasePromptMismatch() {
    let settings = ChatGenerationSettings.codingDefault
    let prefix = [
      GemmaMessageSnapshot(
        role: "user",
        content: """
          System instructions:
          Base prompt.

          User request:
          hello
          """
      )
    ]
    let changedBasePrompt = [
      GemmaMessageSnapshot(
        role: "user",
        content: """
          System instructions:
          Different base prompt.

          User request:
          hello
          """
      )
    ]

    let decision = GemmaMLXRuntime.cacheDecision(
      cachedPrefix: prefix,
      cachedSettings: settings,
      cachedState: .clean,
      currentHistory: changedBasePrompt,
      currentSettings: settings
    )

    #expect(!decision.shouldReuse)
    #expect(decision.trace.cacheReason == .invalidatedToolPromptChanged)
    #expect(decision.trace.mismatchReason == "history_prefix_mismatch")
    #expect(decision.trace.firstMismatchIndex == 0)
    #expect(decision.trace.systemPromptChanged == true)
    #expect(decision.trace.currentPromptContextChanged == false)
  }

  @Test
  func cacheDecisionInvalidatesInFlightSessionAsInterrupted() {
    let settings = ChatGenerationSettings.codingDefault
    let prefix = GemmaMLXRuntime.messageSnapshot(from: [
      .user("hello"),
      .assistant("hi"),
    ])

    let decision = GemmaMLXRuntime.cacheDecision(
      cachedPrefix: prefix,
      cachedSettings: settings,
      cachedState: .inFlight(generationID: GemmaGenerationID(rawValue: 1)),
      currentHistory: prefix,
      currentSettings: settings
    )

    #expect(!decision.shouldReuse)
    #expect(decision.trace.cacheMode == .invalidatedInterrupted)
    #expect(decision.trace.cacheReason == .invalidatedGenInterrupted)
  }

  @Test
  func cacheDecisionInvalidatesAfterDirtyStreamLifecycle() {
    let settings = ChatGenerationSettings.codingDefault
    let prefix = GemmaMLXRuntime.messageSnapshot(from: [
      .user("hello"),
      .assistant("hi"),
    ])

    let cancelled = GemmaMLXRuntime.cacheDecision(
      cachedPrefix: prefix,
      cachedSettings: settings,
      cachedState: .dirty(reason: .cancelled),
      currentHistory: prefix,
      currentSettings: settings
    )
    let interrupted = GemmaMLXRuntime.cacheDecision(
      cachedPrefix: prefix,
      cachedSettings: settings,
      cachedState: .dirty(reason: .interrupted),
      currentHistory: prefix,
      currentSettings: settings
    )
    let downstreamTerminated = GemmaMLXRuntime.cacheDecision(
      cachedPrefix: prefix,
      cachedSettings: settings,
      cachedState: .dirty(reason: .downstreamTerminated),
      currentHistory: prefix,
      currentSettings: settings
    )
    let runtimeError = GemmaMLXRuntime.cacheDecision(
      cachedPrefix: prefix,
      cachedSettings: settings,
      cachedState: .dirty(reason: .runtimeError),
      currentHistory: prefix,
      currentSettings: settings
    )

    #expect(!cancelled.shouldReuse)
    #expect(cancelled.trace.cacheMode == .invalidatedCancelled)
    #expect(cancelled.trace.cacheReason == .invalidatedGenCancelled)
    #expect(!interrupted.shouldReuse)
    #expect(interrupted.trace.cacheMode == .invalidatedInterrupted)
    #expect(interrupted.trace.cacheReason == .invalidatedGenInterrupted)
    #expect(!downstreamTerminated.shouldReuse)
    #expect(downstreamTerminated.trace.cacheMode == .invalidatedDownstreamTerminated)
    #expect(downstreamTerminated.trace.cacheReason == .invalidatedGenDownstreamTerminated)
    #expect(!runtimeError.shouldReuse)
    #expect(runtimeError.trace.cacheMode == .invalidatedRuntimeError)
    #expect(runtimeError.trace.cacheReason == .invalidatedGenRuntimeError)
  }

  @Test
  func modelStreamMarksConsumerTerminationAsDownstreamTerminated() async throws {
    let recorder = GemmaStreamInvalidationRecorder()
    try await consumeFirstModelStreamEvent(recorder: recorder)

    try await waitUntilAsync {
      await recorder.firstReason != nil
    }
    #expect(await recorder.firstReason == .downstreamTerminated)
  }

  @Test
  func modelStreamPlanCancelsUpstreamTaskWhenConsumerTerminates() async throws {
    let recorder = GemmaStreamInvalidationRecorder()
    let source = AsyncThrowingStream<Generation, Error> { continuation in
      let task = Task {
        try? await Task.sleep(for: .seconds(5))
        continuation.yield(.chunk("late"))
      }
      continuation.yield(.chunk("tool"))
      continuation.onTermination = { _ in
        task.cancel()
      }
    }
    var plan: GemmaModelStreamPlan? = GemmaMLXRuntime.modelStreamPlan(
      from: source,
      traceID: UUID(),
      traceMetadata: nil,
      cacheTrace: defaultCacheTrace(),
      markCompleted: { _ in },
      markCancelled: { reason in
        await recorder.record(reason)
      }
    )
    let upstreamTask = try #require(plan?.task)
    var outputStream: AsyncThrowingStream<ChatModelStreamEvent, Error>? = try #require(plan?.stream)
    plan = nil

    let (firstEventStream, firstEventContinuation) = AsyncStream<Void>.makeStream()
    let consumerTask = consumeFirstEventAndWait(
      from: try #require(outputStream),
      firstEventContinuation: firstEventContinuation
    )
    outputStream = nil
    defer {
      consumerTask.cancel()
    }

    _ = try await withTestTimeout(.seconds(5)) {
      var firstEventIterator = firstEventStream.makeAsyncIterator()
      return await firstEventIterator.next()
    }
    consumerTask.cancel()
    try await withTestTimeout(.seconds(5)) {
      await consumerTask.value
    }
    try await waitUntilAsync {
      let firstReason = await recorder.firstReason
      return upstreamTask.isCancelled && firstReason == .downstreamTerminated
    }
  }

  @Test
  func modelStreamMemoryClearPolicyClearsOnlyDirtyRuntimeState() {
    #expect(GemmaMLXRuntime.memoryClearReason(for: .completed) == nil)
    #expect(GemmaMLXRuntime.memoryClearReason(for: .downstreamTerminated) == nil)
    #expect(GemmaMLXRuntime.memoryClearReason(for: .cancelled) == nil)
    #expect(GemmaMLXRuntime.memoryClearReason(for: .nativeToolCallBoundary) == nil)
    #expect(GemmaMLXRuntime.memoryClearReason(for: .runtimeError) == .runtimeError)
    #expect(GemmaMLXRuntime.memoryClearReason(for: .interruptedStream) == .interruptedStream)
  }

  @Test
  func completedModelStreamDoesNotClearMemoryCache() async throws {
    let memoryClearRecorder = GemmaMemoryClearRecorder()
    let source = AsyncThrowingStream<Generation, Error> { continuation in
      continuation.yield(.chunk("done"))
      continuation.yield(
        .info(
          GenerateCompletionInfo(
            promptTokenCount: 8,
            generationTokenCount: 1,
            promptTime: 0.1,
            generationTime: 0.1
          )
        ))
      continuation.finish()
    }
    let stream = GemmaMLXRuntime.modelStream(
      from: source,
      traceID: UUID(),
      traceMetadata: nil,
      cacheTrace: defaultCacheTrace(),
      markCompleted: { _ in },
      markCancelled: { _ in },
      memoryCacheClearer: GemmaMemoryCacheClearer { reason in
        await memoryClearRecorder.record(reason)
      }
    )

    try await drainModelStream(stream)

    #expect(await memoryClearRecorder.reasons.isEmpty)
  }

  @Test
  func cancellationModelStreamDoesNotClearMemoryCache() async throws {
    let memoryClearRecorder = GemmaMemoryClearRecorder()
    let source = AsyncThrowingStream<Generation, Error> { continuation in
      continuation.yield(.chunk("partial"))
      continuation.finish(throwing: CancellationError())
    }
    let stream = GemmaMLXRuntime.modelStream(
      from: source,
      traceID: UUID(),
      traceMetadata: nil,
      cacheTrace: defaultCacheTrace(),
      markCompleted: { _ in },
      markCancelled: { _ in },
      memoryCacheClearer: GemmaMemoryCacheClearer { reason in
        await memoryClearRecorder.record(reason)
      }
    )

    do {
      try await drainModelStream(stream)
      Issue.record("Expected cancellation to propagate from model stream.")
    } catch is CancellationError {
      #expect(await memoryClearRecorder.reasons.isEmpty)
    }
  }

  @Test
  func runtimeErrorModelStreamClearsMemoryCache() async throws {
    let memoryClearRecorder = GemmaMemoryClearRecorder()
    let source = AsyncThrowingStream<Generation, Error> { continuation in
      continuation.yield(.chunk("partial"))
      continuation.finish(throwing: GemmaTestStreamError())
    }
    let stream = GemmaMLXRuntime.modelStream(
      from: source,
      traceID: UUID(),
      traceMetadata: nil,
      cacheTrace: defaultCacheTrace(),
      markCompleted: { _ in },
      markCancelled: { _ in },
      memoryCacheClearer: GemmaMemoryCacheClearer { reason in
        await memoryClearRecorder.record(reason)
      }
    )

    do {
      try await drainModelStream(stream)
      Issue.record("Expected runtime error to propagate from model stream.")
    } catch is GemmaTestStreamError {
      #expect(await memoryClearRecorder.reasons == [.runtimeError])
    }
  }

  @Test
  func interruptedModelStreamClearsMemoryCache() async throws {
    let memoryClearRecorder = GemmaMemoryClearRecorder()
    let source = AsyncThrowingStream<Generation, Error> { continuation in
      continuation.yield(.chunk("partial"))
      continuation.finish()
    }
    let stream = GemmaMLXRuntime.modelStream(
      from: source,
      traceID: UUID(),
      traceMetadata: nil,
      cacheTrace: defaultCacheTrace(),
      markCompleted: { _ in },
      markCancelled: { _ in },
      memoryCacheClearer: GemmaMemoryCacheClearer { reason in
        await memoryClearRecorder.record(reason)
      }
    )

    do {
      try await drainModelStream(stream)
      Issue.record("Expected interrupted stream to throw.")
    } catch GemmaMLXRuntimeError.interruptedStream {
      #expect(await memoryClearRecorder.reasons == [.interruptedStream])
    } catch {
      Issue.record("Expected interrupted stream error, got \(error).")
    }
  }

  @Test
  func unloadAndClearContextClearMemoryCacheWithExplicitReasons() async {
    let memoryClearRecorder = GemmaMemoryClearRecorder()
    let runtime = GemmaMLXRuntime(
      memoryCacheClearer: GemmaMemoryCacheClearer { reason in
        await memoryClearRecorder.record(reason)
      })

    await runtime.unload()
    await runtime.clearContext()

    #expect(await memoryClearRecorder.reasons == [.unload, .clearContext])
  }

  @Test
  func unloadWaitsForActiveGenerationToDrainBeforeClearingMemoryCache() async throws {
    try await assertLifecycleOperationDrainsBeforeMemoryClear(reason: .unload) { runtime in
      await runtime.unload()
    }
  }

  @Test
  func clearContextWaitsForActiveGenerationToDrainBeforeClearingMemoryCache() async throws {
    try await assertLifecycleOperationDrainsBeforeMemoryClear(reason: .clearContext) { runtime in
      await runtime.clearContext()
    }
  }

  @Test
  func modelStreamCompletesNativeToolCallAsCleanBoundary() async throws {
    let recorder = GemmaStreamInvalidationRecorder()
    let boundaryRecorder = GemmaNativeBoundaryRecorder()
    let memoryClearRecorder = GemmaMemoryClearRecorder()
    let toolCall = MLXLMCommon.ToolCall(
      function: .init(
        name: "read_file",
        arguments: ["path": "README.md"]
      )
    )
    let source = AsyncThrowingStream<Generation, Error> { continuation in
      continuation.yield(.toolCall(toolCall))
      continuation.yield(
        .info(
          GenerateCompletionInfo(
            promptTokenCount: 8,
            generationTokenCount: 1,
            promptTime: 0.1,
            generationTime: 0.1
          )
        ))
      continuation.finish()
    }
    let stream = GemmaMLXRuntime.modelStream(
      from: source,
      traceID: UUID(),
      traceMetadata: nil,
      cacheTrace: defaultCacheTrace(),
      markCompleted: { _ in
        await recorder.record(.signatureMismatch)
      },
      markNativeToolCallBoundary: { output, nativeToolCalls in
        await boundaryRecorder.record(output: output, nativeToolCalls: nativeToolCalls)
      },
      markCancelled: { reason in
        await recorder.record(reason)
      },
      memoryCacheClearer: GemmaMemoryCacheClearer { reason in
        await memoryClearRecorder.record(reason)
      }
    )

    var iterator = stream.makeAsyncIterator()
    let firstEvent = try await iterator.next()
    guard case .toolCall(let runtimeToolCall) = firstEvent else {
      Issue.record("Expected native tool call to be forwarded to the chat runtime.")
      return
    }
    #expect(runtimeToolCall.name == "read_file")

    _ = try await iterator.next()
    try await waitUntilAsync {
      await boundaryRecorder.firstBoundary?.nativeToolCalls.count == 1
    }
    #expect(await recorder.firstReason == nil)
    #expect(await boundaryRecorder.firstBoundary?.output == "")
    #expect(await boundaryRecorder.firstBoundary?.nativeToolCalls.first?.name == "read_file")
    #expect(await memoryClearRecorder.reasons.isEmpty)
  }

  @Test
  func nativeGemma4ToolContextMapsRegistryToMLXToolSpecs() throws {
    let toolContext = ChatRuntimeToolContext(
      strategy: .nativeGemma4,
      registry: ToolExecutorRegistry.readOnly.toolRegistry
    )

    let specs = try #require(GemmaMLXRuntime.toolSpecs(from: toolContext))
    let readFileSpec = try #require(
      specs.first { spec in
        let function = spec["function"] as? [String: any Sendable]
        return function?["name"] as? String == "read_file"
      })
    let function = try #require(readFileSpec["function"] as? [String: any Sendable])
    let parameters = try #require(function["parameters"] as? [String: any Sendable])
    let properties = try #require(parameters["properties"] as? [String: any Sendable])
    let path = try #require(properties["path"] as? [String: any Sendable])
    let limit = try #require(properties["limit"] as? [String: any Sendable])

    #expect(readFileSpec["type"] as? String == "function")
    #expect(function["description"] as? String == ToolDefinition.readFile.description)
    #expect(parameters["type"] as? String == "object")
    #expect(parameters["additionalProperties"] as? Bool == false)
    #expect(path["type"] as? String == "string")
    #expect(limit["type"] as? String == "integer")
  }

  @Test
  func nativeGemma4ToolContextDefinesSimpleParametersAsStrings() throws {
    let toolContext = ChatRuntimeToolContext(
      strategy: .nativeGemma4,
      registry: ToolExecutorRegistry.codingAgent.toolRegistry
    )

    let specs = try #require(GemmaMLXRuntime.toolSpecs(from: toolContext))
    let todoSpec = try #require(
      specs.first { spec in
        let function = spec["function"] as? [String: any Sendable]
        return function?["name"] as? String == "todo_write"
      })
    let function = try #require(todoSpec["function"] as? [String: any Sendable])
    let parameters = try #require(function["parameters"] as? [String: any Sendable])
    let properties = try #require(parameters["properties"] as? [String: any Sendable])
    let items = try #require(properties["items"] as? [String: any Sendable])
    let askSpec = try #require(
      specs.first { spec in
        let function = spec["function"] as? [String: any Sendable]
        return function?["name"] as? String == "ask_user"
      })
    let askFunction = try #require(askSpec["function"] as? [String: any Sendable])
    let askParameters = try #require(askFunction["parameters"] as? [String: any Sendable])
    let askProperties = try #require(askParameters["properties"] as? [String: any Sendable])
    let option1 = try #require(askProperties["option1"] as? [String: any Sendable])
    let option2 = try #require(askProperties["option2"] as? [String: any Sendable])

    #expect(items["type"] as? String == "string")
    #expect((items["description"] as? String)?.contains("JSON array string") == true)
    #expect(items["items"] == nil)
    #expect(option1["type"] as? String == "string")
    #expect(option1["items"] == nil)
    #expect(option2["type"] as? String == "string")
    #expect(option2["items"] == nil)
  }

  @Test
  func mlxToolCallMapsToRuntimeToolCallArguments() {
    let mlxToolCall = MLXLMCommon.ToolCall(
      function: .init(
        name: "read_file",
        arguments: [
          "path": .string("README.md"),
          "limit": .int(20),
          "include_hidden": .bool(false),
        ]
      )
    )

    let runtimeToolCall = GemmaMLXRuntime.chatRuntimeToolCall(from: mlxToolCall)

    #expect(runtimeToolCall.name == "read_file")
    #expect(runtimeToolCall.arguments["path"] == .string("README.md"))
    #expect(runtimeToolCall.arguments["limit"] == .number(20))
    #expect(runtimeToolCall.arguments["include_hidden"] == .bool(false))
    #expect(runtimeToolCall.rawText == NativeToolCallBoundaryRenderer.renderGemma4(runtimeToolCall))
  }

  private func consumeFirstEventAndWait(
    from stream: AsyncThrowingStream<ChatModelStreamEvent, Error>,
    firstEventContinuation: AsyncStream<Void>.Continuation
  ) -> Task<Void, Never> {
    Task {
      do {
        let firstEvent = try await withTestTimeout(.seconds(5)) {
          var iterator = stream.makeAsyncIterator()
          return try await iterator.next()
        }
        guard case .chunk("tool") = firstEvent else {
          Issue.record("Expected first model stream event to be the initial chunk.")
          firstEventContinuation.finish()
          return
        }
        firstEventContinuation.yield(())
        firstEventContinuation.finish()
        try await Task.sleep(for: .seconds(5))
      } catch {
        firstEventContinuation.finish()
      }
    }
  }

  private func consumeFirstModelStreamEvent(recorder: GemmaStreamInvalidationRecorder) async throws
  {
    let source = AsyncThrowingStream<Generation, Error> { continuation in
      let task = Task {
        continuation.yield(.chunk("tool"))
        try? await Task.sleep(for: .seconds(5))
        continuation.yield(.chunk("late"))
      }
      continuation.onTermination = { _ in
        task.cancel()
      }
    }
    let stream = GemmaMLXRuntime.modelStream(
      from: source,
      traceID: UUID(),
      traceMetadata: nil,
      cacheTrace: defaultCacheTrace(),
      markCompleted: { _ in },
      markCancelled: { reason in
        await recorder.record(reason)
      }
    )

    do {
      let firstEvent = try await withTestTimeout(.seconds(5)) {
        var iterator = stream.makeAsyncIterator()
        return try await iterator.next()
      }
      guard case .chunk("tool") = firstEvent else {
        Issue.record("Expected first model stream event to be the initial chunk.")
        return
      }
    }
  }

  private func drainModelStream(
    _ stream: AsyncThrowingStream<ChatModelStreamEvent, Error>
  ) async throws {
    var iterator = stream.makeAsyncIterator()
    while try await iterator.next() != nil {}
  }

  private func assertLifecycleOperationDrainsBeforeMemoryClear(
    reason: GemmaMemoryClearReason,
    operation: @escaping @Sendable (GemmaMLXRuntime) async -> Void
  ) async throws {
    let recorder = GemmaLifecycleDrainRecorder()
    let runtime = GemmaMLXRuntime(
      memoryCacheClearer: GemmaMemoryCacheClearer { reason in
        await recorder.record(.memoryClear(reason))
      })
    let task = Task<Void, Never> {
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(10))
      }
      await recorder.record(.taskCancelled)
      await recorder.waitUntilAllowedToFinish()
      await recorder.record(.taskFinished)
    }
    await runtime.registerActiveGenerationForTesting(id: GemmaGenerationID(rawValue: 1), task: task)

    let lifecycleTask = Task {
      await operation(runtime)
    }
    defer {
      task.cancel()
      lifecycleTask.cancel()
    }

    try await waitUntilAsync {
      await recorder.events.contains(.taskCancelled)
    }
    #expect(await recorder.events == [.taskCancelled])

    await recorder.allowTaskToFinish()
    try await withTestTimeout(.seconds(5)) {
      await lifecycleTask.value
    }

    #expect(await recorder.events == [.taskCancelled, .taskFinished, .memoryClear(reason)])
  }

  private func projectedEntries(
    from entries: [ModelContextEntry]
  ) throws -> [ProjectedModelContextEntry] {
    try ModelContextSnapshot(entries: entries)
      .runtimeProjectedEntries(mode: .compactedHistoryForLaterTurns)
  }

  private func generationHistoryAndPrompt(
    from entries: [ModelContextEntry]
  ) throws -> (history: [Chat.Message], prompt: Chat.Message) {
    let projectedEntries = try projectedEntries(from: entries)
    let lastUserIndex = try #require(projectedEntries.lastIndex { $0.role == .user })
    let history = try GemmaMLXRuntime.generationHistoryMessages(
      from: projectedEntries[..<lastUserIndex]
    )
    let prompt = GemmaMLXRuntime.chatMessage(from: projectedEntries[lastUserIndex])
    return (history, prompt)
  }

  private func writeFileToolCall(
    callID: UUID,
    arguments: ToolCallArguments
  ) -> ToolCallModelMessage {
    ToolCallModelMessage(
      rawRequest: RawToolCallRequest(
        id: callID,
        workspaceID: UUID(),
        sessionID: UUID(),
        toolName: .writeFile,
        arguments: arguments
      ))
  }

  private func toolRequest(
    callID: UUID,
    toolName: ToolName,
    arguments: ToolCallArguments
  ) -> ToolCallRequest {
    let rawRequest = RawToolCallRequest(
      id: callID,
      workspaceID: UUID(),
      sessionID: UUID(),
      toolName: toolName,
      arguments: arguments
    )
    return ToolCallRequestValidator().validate(
      rawRequest,
      registry: ToolExecutorRegistry.codingAgent.toolRegistry
    )
  }

  private func defaultCacheTrace() -> GemmaSessionCacheTrace {
    GemmaSessionCacheTrace(
      cacheMode: .newSessionHistory,
      cacheReason: .newSessionNoCache,
      contextSignature: "context",
      previousContextSignature: nil,
      appendOnly: false,
      reusedMessageCount: 0,
      appendedMessageCount: 0,
      mismatchReason: nil,
      firstMismatchIndex: nil,
      systemPromptChanged: nil,
      currentPromptContextChanged: nil,
      cacheEligibility: "enabled",
      cacheEligibilityReason: nil
    )
  }
}

private actor GemmaStreamInvalidationRecorder {
  private var reasons: [GemmaSessionInvalidationReason] = []

  var firstReason: GemmaSessionInvalidationReason? {
    reasons.first
  }

  func record(_ reason: GemmaSessionInvalidationReason) {
    reasons.append(reason)
  }
}

private actor GemmaNativeBoundaryRecorder {
  private var boundaries: [(output: String, nativeToolCalls: [ChatRuntimeToolCall])] = []

  var firstBoundary: (output: String, nativeToolCalls: [ChatRuntimeToolCall])? {
    boundaries.first
  }

  func record(output: String, nativeToolCalls: [ChatRuntimeToolCall]) {
    boundaries.append((output, nativeToolCalls))
  }
}

private actor GemmaMemoryClearRecorder {
  private var recordedReasons: [GemmaMemoryClearReason] = []

  var reasons: [GemmaMemoryClearReason] {
    recordedReasons
  }

  func record(_ reason: GemmaMemoryClearReason) {
    recordedReasons.append(reason)
  }
}

private enum GemmaLifecycleDrainEvent: Equatable {
  case taskCancelled
  case taskFinished
  case memoryClear(GemmaMemoryClearReason)
}

private actor GemmaLifecycleDrainRecorder {
  private var recordedEvents: [GemmaLifecycleDrainEvent] = []
  private var shouldFinish = false
  private var finishContinuation: CheckedContinuation<Void, Never>?

  var events: [GemmaLifecycleDrainEvent] {
    recordedEvents
  }

  func record(_ event: GemmaLifecycleDrainEvent) {
    recordedEvents.append(event)
  }

  func waitUntilAllowedToFinish() async {
    if shouldFinish {
      return
    }

    await withCheckedContinuation { continuation in
      finishContinuation = continuation
    }
  }

  func allowTaskToFinish() {
    shouldFinish = true
    finishContinuation?.resume()
    finishContinuation = nil
  }
}

private struct GemmaTestStreamError: Error {}

private struct GemmaStreamWaitTimeoutError: Error {}

private func waitUntilAsync(
  timeout: Duration = .seconds(2),
  condition: () async -> Bool
) async throws {
  let start = ContinuousClock.now
  while await condition() == false {
    if ContinuousClock.now - start > timeout {
      throw GemmaStreamWaitTimeoutError()
    }
    try await Task.sleep(for: .milliseconds(10))
  }
}
