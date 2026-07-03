import Foundation
import MLXLMCommon
import SumikaCore
import Testing

@testable import Sumika

private let finalToolResultInstruction = """
  Provide a brief final response based on the preceding tool result.
  Mention completed changes, affected paths, and run or verification steps if useful.
  Do not include generated file contents, code blocks, diffs, or tool arguments unless the user explicitly asked to display them in chat.
  If more work is needed, say what remains and ask the user to send another message.
  """

@Suite
struct GemmaMLXRuntimeTemplateTests {
  @Test
  func neutralRepetitionPenaltyDoesNotEnableMLXProcessor() {
    #expect(GemmaMLXRuntime.mlxRepetitionPenalty(from: .agentDefault) == nil)

    var settings = ChatGenerationSettings.agentDefault
    settings.repetitionPenalty = 1.15

    #expect(GemmaMLXRuntime.mlxRepetitionPenalty(from: settings) == 1.15)
  }

  @Test
  func imageInputsUseAttachmentFileURLs() throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appending(
        path: "sumika-runtime-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
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

    let images = try GemmaHistoryRenderer.imageInputs(from: [attachment], attachmentStore: store)

    #expect(images.count == 1)
    guard case .url(let imageURL) = try #require(images.first) else {
      Issue.record("Expected URL-backed image input.")
      return
    }
    #expect(imageURL.lastPathComponent == storedURL.lastPathComponent)
    #expect(try Data(contentsOf: imageURL) == data)
  }

  @Test
  func generationHistorySnapshotCarriesImageSignaturesFromUserPromptEntry() throws {
    let imageAttachment = ChatAttachment(
      displayName: "car.jpg",
      payload: .image(
        ImageAttachmentPayload(mimeType: "image/jpeg", byteSize: 1024, contentSHA256: "abc123")
      )
    )
    let entries = [
      try ModelFacingPromptRenderer.userPromptEntry(
        prompt: "what is in the picture",
        attachments: [imageAttachment]
      ),
      try ModelFacingPromptRenderer.assistantOutputEntry(content: "A blue Mini Cooper."),
      try ModelFacingPromptRenderer.userPromptEntry(prompt: "what color are the wheels?"),
    ]

    let snapshot = GemmaHistoryRenderer.generationHistorySnapshot(
      from: projectedEntries(from: entries)[..<2]
    )

    #expect(snapshot.count == 2)
    #expect(snapshot[0].imageSignatures == ["sha256:abc123"])
    #expect(snapshot[1].imageSignatures == [])
    #expect(snapshot[0].content.contains("abc123") == false)
  }

  @Test
  func cachePrefixComparisonIncludesImageSignatures() {
    let cachedPrefix = [
      GemmaMessageSnapshot(
        role: "user",
        content: "what is in the picture",
        imageSignatures: ["sha256:abc"]
      ),
      GemmaMessageSnapshot(role: "assistant", content: "A blue Mini Cooper."),
    ]
    let currentHistory = [
      GemmaMessageSnapshot(
        role: "user",
        content: "what is in the picture",
        imageSignatures: ["sha256:other"]
      ),
      GemmaMessageSnapshot(role: "assistant", content: "A blue Mini Cooper."),
    ]

    #expect(GemmaSessionCachePolicy.isPrefix(cachedPrefix, of: cachedPrefix))
    #expect(!GemmaSessionCachePolicy.isPrefix(cachedPrefix, of: currentHistory))
    #expect(
      GemmaSessionCachePolicy.firstMismatchIndex(
        cachedPrefix: cachedPrefix,
        currentHistory: currentHistory
      ) == 0)
    #expect(
      GemmaSessionCachePolicy.contextSignature(for: cachedPrefix)
        != GemmaSessionCachePolicy.contextSignature(for: currentHistory))
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
          ),
          originalUserRequest: nil
        ),
        try ModelFacingPromptRenderer.userPromptEntry(
          prompt: "change the background color to green",
          systemContext: ["Use concise coding steps."]
        ),
      ]
    )

    let rendered = try GemmaHistoryRenderer.templateMessages(
      from: transcript,
      attachments: [],
      systemPrompt: "This runtime argument must not rewrite frozen content."
    )
    let rawMessages = DefaultMessageGenerator().generate(messages: rendered)
    let rawAssistantToolCalls = try #require(
      rawMessages[2]["tool_calls"] as? [[String: any Sendable]]
    )
    let rawAssistantToolCall = try #require(rawAssistantToolCalls.first)
    let rawAssistantFunction = try #require(
      rawAssistantToolCall["function"] as? [String: any Sendable]
    )

    #expect(rendered[0].role == .system)
    #expect(rendered.map(\.role) == [.system, .user, .assistant, .tool, .user])
    #expect(!rendered[1].content.contains("System instructions:"))
    #expect(rendered[0].content.contains("This runtime argument must not rewrite"))
    #expect(rendered[4].content.contains("System instructions:"))
    #expect(rendered[4].content.contains("Use concise coding steps."))
    #expect(!rendered[4].content.contains("This runtime argument must not rewrite"))
    #expect(rendered[2].content.isEmpty)
    #expect(rawAssistantFunction["name"] as? String == ToolName.writeFile.rawValue)
    #expect(rendered[3].content.contains("<observation"))
    #expect(rendered[3].content.contains("Summary:"))
    #expect(rendered[3].content.contains("Wrote 13 bytes to index.htm."))
    #expect(rendered[3].content.contains("Tool receipt:") == false)
  }

  @Test
  func runtimeHistoryPrependsSystemPromptWithoutEmbeddingItInUserHistory() throws {
    let callID = UUID()
    let entries = [
      try ModelFacingPromptRenderer.userPromptEntry(
        prompt: "create index.htm"
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
        ),
        originalUserRequest: nil
      ),
    ]

    let projectedHistory = try GemmaHistoryRenderer.generationHistoryMessages(
      from: projectedEntries(from: entries)[...]
    )
    let history = try GemmaHistoryRenderer.runtimeHistoryMessages(
      systemPrompt: "Use concise coding steps.",
      history: projectedHistory
    )

    #expect(history.map(\.role) == [.system, .user, .assistant, .tool])
    #expect(history[0].content.contains("Use concise coding steps."))
    #expect(!history[1].content.contains("System instructions:"))
    #expect(!history[1].content.contains("Use concise coding steps."))
    #expect(!history[3].content.contains("Use concise coding steps."))
  }

  @Test
  func renderedHistoryDoesNotRewriteFirstUserWhenToolPromptModeChanges() throws {
    let initialUser = try ModelFacingPromptRenderer.userPromptEntry(
      prompt: "create index.htm",
      systemContext: ["When tools are available, use them."]
    )
    let initialRendered = try GemmaHistoryRenderer.templateMessages(
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

    let history = try GemmaHistoryRenderer.generationHistoryMessages(
      from: projectedEntries(from: entries)[...]
    )

    #expect(history.map(\.role) == [.user, .assistant, .user, .assistant])
    #expect(history[0].content == initialRendered[1].content)
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
            """
            Current focused file: index.htm
            Source: previous write_file
            Known content excerpt:
            <html><body><table><tr><td>Movie</td></tr></table></body></html>
            Explicit file paths in the user request or tool call take precedence.
            """
          ]
        )
      ]
    )

    let rendered = try GemmaHistoryRenderer.templateMessages(
      from: transcript,
      attachments: [],
      systemPrompt: "A later runtime argument must not rewrite frozen content."
    )

    #expect(rendered.map(\.role) == [.system, .user])
    #expect(rendered[0].content.contains("A later runtime argument must not rewrite"))
    #expect(rendered[1].content.contains("Current focused file: index.htm"))
    #expect(rendered[1].content.contains("<html><body><table>"))
    #expect(rendered[1].content.contains("User request:"))
    #expect(rendered[1].content.contains("change the background color to green"))
  }

  @Test
  func generationPromptPreservesFocusedFileSystemContextOnFirstTurn() throws {
    let entries = [
      try ModelFacingPromptRenderer.userPromptEntry(
        prompt: "explain this",
        systemContext: [
          """
          Current focused file: index.htm
          Source: previous read_file
          Known content excerpt:
          <h1>Dashboard</h1>
          Explicit file paths in the user request or tool call take precedence.
          """
        ]
      )
    ]
    let (history, prompt) = try generationHistoryAndPrompt(from: entries)

    #expect(history.isEmpty)
    #expect(!prompt.content.contains("Use concise coding steps."))
    #expect(prompt.content.contains("Current focused file: index.htm"))
    #expect(prompt.content.contains("<h1>Dashboard</h1>"))
    #expect(prompt.content.contains("User request:"))
    #expect(prompt.content.contains("explain this"))
  }

  @Test
  func currentPromptContextDoesNotRewriteHistoricalUserMessage() throws {
    let initialUser = try ModelFacingPromptRenderer.userPromptEntry(
      prompt: "summarize the current page",
      systemContext: []
    )
    let initialRendered = try GemmaHistoryRenderer.templateMessages(
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
          """
          Current focused file: robots.html
          Source: previous read_file
          Known content excerpt:
          <table><tr><td>Robot</td></tr></table>
          Explicit file paths in the user request or tool call take precedence.
          """
        ]
      ),
    ]
    let (history, prompt) = try generationHistoryAndPrompt(from: entries)

    #expect(history.map(\.role) == [.user, .assistant])
    #expect(history[0].content == initialRendered[1].content)
    #expect(!history[0].content.contains("Current focused file: robots.html"))
    #expect(!history[0].content.contains("No more tools may run in this response."))
    #expect(!prompt.content.contains("No more tools may run in this response."))
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
          ),
          originalUserRequest: "change the table heading"
        ),
      ]
    )

    let rendered = try GemmaHistoryRenderer.templateMessages(
      from: transcript,
      attachments: [],
      systemPrompt: "Use concise coding steps."
    )

    #expect(rendered.map(\.role) == [.system, .user])
    #expect(!rendered.contains { $0.content.contains("<|tool_call>call:invalid") })
    #expect(rendered[1].content.contains("The tool call was invalid"))
  }

  @Test
  func cacheIdentityIgnoresDecodeOnlySettings() {
    var changedSettings = ChatGenerationSettings.agentDefault
    changedSettings.maxTokens = 128
    changedSettings.temperature = 0.9
    changedSettings.topP = 0.5
    changedSettings.topK = 40
    changedSettings.repetitionPenalty = 1.15

    let first = GemmaSessionCachePolicy.cacheIdentity(
      systemPrompt: "Use concise coding steps.",
      settings: .agentDefault,
      projectionMode: .fullHistory
    )
    let second = GemmaSessionCachePolicy.cacheIdentity(
      systemPrompt: "Use concise coding steps.",
      settings: changedSettings,
      projectionMode: .fullHistory
    )

    #expect(first == second)
  }

  @Test
  func cacheIdentityChangesForPrefillSettings() {
    var changedMaxKV = ChatGenerationSettings.agentDefault
    changedMaxKV.maxKVSize = 16_384
    var changedReasoning = ChatGenerationSettings.agentDefault
    changedReasoning.reasoningEnabled = false
    let base = GemmaSessionCachePolicy.cacheIdentity(
      systemPrompt: "Use concise coding steps.",
      settings: .agentDefault,
      projectionMode: .fullHistory
    )

    #expect(
      GemmaSessionCachePolicy.identityMismatchReason(
        cached: base,
        current: GemmaSessionCachePolicy.cacheIdentity(
          systemPrompt: "Use concise coding steps.",
          settings: changedMaxKV,
          projectionMode: .fullHistory
        )
      ) == .maxKVSizeChanged)
    #expect(
      GemmaSessionCachePolicy.identityMismatchReason(
        cached: base,
        current: GemmaSessionCachePolicy.cacheIdentity(
          systemPrompt: "Use concise coding steps.",
          settings: changedReasoning,
          projectionMode: .fullHistory
        )
      ) == .reasoningChanged)
    #expect(
      GemmaSessionCachePolicy.identityMismatchReason(
        cached: base,
        current: GemmaSessionCachePolicy.cacheIdentity(
          systemPrompt: "Use detailed coding steps.",
          settings: .agentDefault,
          projectionMode: .fullHistory
        )
      ) == .identityChanged)
  }

  @Test
  func streamMessagesUsesOnlyAppendDeltaAndPrompt() {
    let history: [Chat.Message] = [
      .user("hello"),
      .assistant("hi"),
      .tool("result", id: "call_1"),
    ]
    let promptMessages: [Chat.Message] = [.user("continue")]

    let firstPrompt = GemmaSessionCachePolicy.streamMessages(
      history: history,
      promptMessages: promptMessages,
      appendDeltaStartIndex: nil
    )
    let appendDelta = GemmaSessionCachePolicy.streamMessages(
      history: history,
      promptMessages: promptMessages,
      appendDeltaStartIndex: 2
    )

    #expect(firstPrompt.map(\.role) == [.user])
    #expect(appendDelta.map(\.role) == [.tool, .user])
  }

  @Test
  func runtimeCacheDebugSnapshotMapsCoarseTrace() {
    let generationID = UUID()
    let recordedAt = Date(timeIntervalSince1970: 42)
    let trace = GemmaSessionCacheTrace(
      cacheMode: .appendDelta,
      cacheReason: .appendOnlyDelta,
      contextSignature: "ctx-new",
      previousContextSignature: "ctx-old",
      appendOnly: true,
      reusedMessageCount: 3,
      appendedMessageCount: 1,
      mismatchReason: nil,
      firstMismatchIndex: nil,
      systemPromptChanged: nil,
      currentPromptContextChanged: nil
    )

    let snapshot = GemmaSessionCachePolicy.runtimeCacheDebugSnapshot(
      from: trace,
      appendDeltaStartIndex: 3,
      generationID: generationID,
      recordedAt: recordedAt
    )

    #expect(snapshot.generationID == generationID)
    #expect(snapshot.recordedAt == recordedAt)
    #expect(snapshot.cacheMode == "append_delta")
    #expect(snapshot.cacheReason == "append_only_delta")
    #expect(snapshot.reuseStrategy == "append_delta")
    #expect(snapshot.appendDeltaStartIndex == 3)
    #expect(snapshot.contextSignature == "ctx-new")
    #expect(snapshot.previousContextSignature == "ctx-old")
    #expect(snapshot.appendOnly)
    #expect(snapshot.reusedMessageCount == 3)
    #expect(snapshot.appendedMessageCount == 1)
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
    #expect(!GemmaCachedSessionState.inFlight(generationID: generationID).isReusable)
    #expect(!GemmaCachedSessionState.dirty(reason: .cancelled).isReusable)
    #expect(GemmaCachedSessionState.clean.invalidationReason == nil)
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
    #expect(inFlight.invalidating(generationID: first, reason: .cancelled) == nil)
    #expect(inFlight.completing(generationID: second) == .clean)
    #expect(
      inFlight.invalidating(generationID: second, reason: .downstreamTerminated)
        == .dirty(reason: .downstreamTerminated))
  }

  @Test
  func toolObservationFollowUpUsesStructuredToolResultPromptBatch() throws {
    let callID = UUID()
    let turnID = UUID()
    let entries = [
      try ModelFacingPromptRenderer.userPromptEntry(
        turnID: turnID,
        prompt: "read README.md"
      ),
      try ModelFacingPromptRenderer.assistantOutputEntry(
        turnID: turnID,
        content: toolCallContent(
          callID: callID,
          toolName: .readFile,
          arguments: ["path": .string("README.md")]
        )
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
        originalUserRequest: "read README.md"
      ),
    ]
    let input = try generationInput(from: entries)

    #expect(input.history.map(\.role) == [.user, .assistant])
    #expect(input.promptMessages.map(\.role) == [.tool])
    let rawMessages = DefaultMessageGenerator().generate(
      messages: input.history + input.promptMessages
    )
    let rawAssistantToolCalls = try #require(
      rawMessages[1]["tool_calls"] as? [[String: any Sendable]]
    )
    let rawAssistantToolCall = try #require(rawAssistantToolCalls.first)
    let rawAssistantFunction = try #require(
      rawAssistantToolCall["function"] as? [String: any Sendable]
    )
    #expect(rawAssistantToolCall["id"] as? String == RuntimeToolCallID.string(for: callID))
    #expect(rawAssistantFunction["name"] as? String == ToolName.readFile.rawValue)
    #expect(rawMessages[2]["tool_call_id"] as? String == RuntimeToolCallID.string(for: callID))
    #expect(input.promptMessages[0].content.contains("<observation"))
    #expect(input.promptMessages[0].content.contains("Project overview"))
    #expect(input.promptSnapshot.map(\.role) == ["tool"])
    #expect(input.promptSnapshot[0].toolCallID == RuntimeToolCallID.string(for: callID))
  }

  @Test
  func multipleToolObservationFollowUpUsesStructuredToolResultPromptBatch() throws {
    let readCallID = UUID()
    let listCallID = UUID()
    let turnID = UUID()
    let readArguments: ToolCallArguments = ["path": .string("README.md")]
    let listArguments: ToolCallArguments = ["path": .string(".")]
    let entries = [
      try ModelFacingPromptRenderer.userPromptEntry(
        turnID: turnID,
        prompt: "read README.md and list files"
      ),
      try ModelFacingPromptRenderer.assistantOutputEntry(
        turnID: turnID,
        content: [
          toolCallContent(callID: readCallID, toolName: .readFile, arguments: readArguments),
          toolCallContent(callID: listCallID, toolName: .listFiles, arguments: listArguments),
        ].joined(separator: "\n")
      ),
      try ModelFacingPromptRenderer.toolResultEntry(
        turnID: turnID,
        toolResult: ToolResultModelMessage(
          callID: readCallID,
          toolName: .readFile,
          payload: .readFile(
            .success(
              path: WorkspaceRelativePath(rawValue: "README.md"),
              content: ToolTextOutput(text: "Project overview")
            ))
        ),
        request: toolRequest(
          callID: readCallID,
          toolName: .readFile,
          arguments: readArguments
        ),
        originalUserRequest: "read README.md and list files"
      ),
      try ModelFacingPromptRenderer.toolResultEntry(
        turnID: turnID,
        toolResult: ToolResultModelMessage(
          callID: listCallID,
          toolName: .listFiles,
          payload: .listFiles(
            ListFilesResult(
              root: WorkspaceRelativePath(rawValue: "."),
              entries: [
                WorkspaceFileEntry(
                  path: WorkspaceRelativePath(rawValue: "README.md"),
                  kind: .file,
                )
              ]
            ))
        ),
        request: toolRequest(
          callID: listCallID,
          toolName: .listFiles,
          arguments: listArguments
        ),
        originalUserRequest: "read README.md and list files"
      ),
    ]

    let input = try generationInput(from: entries)

    #expect(input.history.map(\.role) == [.user, .assistant])
    let rawMessages = DefaultMessageGenerator().generate(
      messages: input.history + input.promptMessages
    )
    let rawAssistantToolCalls = try #require(
      rawMessages[1]["tool_calls"] as? [[String: any Sendable]]
    )
    #expect(rawAssistantToolCalls.count == 2)
    let firstToolCall = try #require(rawAssistantToolCalls.first)
    let secondToolCall = try #require(rawAssistantToolCalls.dropFirst().first)
    let firstFunction = try #require(firstToolCall["function"] as? [String: any Sendable])
    let secondFunction = try #require(secondToolCall["function"] as? [String: any Sendable])
    #expect(firstToolCall["id"] as? String == RuntimeToolCallID.string(for: readCallID))
    #expect(firstFunction["name"] as? String == ToolName.readFile.rawValue)
    #expect(secondToolCall["id"] as? String == RuntimeToolCallID.string(for: listCallID))
    #expect(secondFunction["name"] as? String == ToolName.listFiles.rawValue)
    #expect(input.promptMessages.map(\.role) == [.tool, .tool])
    #expect(rawMessages[2]["tool_call_id"] as? String == RuntimeToolCallID.string(for: readCallID))
    #expect(rawMessages[3]["tool_call_id"] as? String == RuntimeToolCallID.string(for: listCallID))
  }

  @Test
  func toolCallAfterAssistantPreambleReplaysAsSingleStructuredAssistantMessage() throws {
    let callID = UUID()
    let turnID = UUID()
    let arguments: ToolCallArguments = ["path": .string("README.md")]
    let entries = [
      try ModelFacingPromptRenderer.userPromptEntry(turnID: turnID, prompt: "read README.md"),
      try ModelFacingPromptRenderer.assistantOutputEntry(
        turnID: turnID,
        content: "I'll inspect that."
      ),
      try ModelFacingPromptRenderer.assistantOutputEntry(
        turnID: turnID,
        content: toolCallContent(
          callID: callID,
          toolName: .readFile,
          arguments: arguments
        )
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
        request: toolRequest(callID: callID, toolName: .readFile, arguments: arguments),
        originalUserRequest: "read README.md"
      ),
    ]

    let input = try generationInput(from: entries)

    #expect(input.history.map(\.role) == [.user, .assistant])
    #expect(input.historySnapshot[1].content == "I'll inspect that.")
    #expect(input.historySnapshot[1].toolCalls.count == 1)
    #expect(input.promptMessages.map(\.role) == [.tool])
  }

  @Test
  func redactedWriteFileBoundaryReplaysAsStructuredToolCall() throws {
    let callID = UUID()
    let turnID = UUID()
    let arguments: ToolCallArguments = [
      "path": .string("movies.html"),
      "content": .string("<html></html>"),
    ]
    let entries = [
      try ModelFacingPromptRenderer.userPromptEntry(turnID: turnID, prompt: "create movies.html"),
      try ModelFacingPromptRenderer.assistantOutputEntry(
        turnID: turnID,
        content: writeFileToolCall(callID: callID, arguments: arguments).modelContextContent
      ),
      try ModelFacingPromptRenderer.toolResultEntry(
        turnID: turnID,
        toolResult: ToolResultModelMessage(
          callID: callID,
          toolName: .writeFile,
          payload: .writeFile(
            .success(path: WorkspaceRelativePath(rawValue: "movies.html"), bytesWritten: 13))
        ),
        request: toolRequest(callID: callID, toolName: .writeFile, arguments: arguments),
        originalUserRequest: "create movies.html"
      ),
    ]

    let input = try generationInput(from: entries)
    let rawMessages = DefaultMessageGenerator().generate(
      messages: input.history + input.promptMessages
    )
    let rawAssistantToolCalls = try #require(
      rawMessages[1]["tool_calls"] as? [[String: any Sendable]]
    )
    let rawAssistantToolCall = try #require(rawAssistantToolCalls.first)
    let rawAssistantFunction = try #require(
      rawAssistantToolCall["function"] as? [String: any Sendable]
    )
    let rawArguments = try #require(rawAssistantFunction["arguments"] as? [String: any Sendable])

    #expect(input.history.map(\.role) == [.user, .assistant])
    #expect(input.historySnapshot[1].content.isEmpty)
    #expect(rawAssistantToolCall["id"] as? String == RuntimeToolCallID.string(for: callID))
    #expect(rawAssistantFunction["name"] as? String == ToolName.writeFile.rawValue)
    #expect(rawArguments["content"] as? String == "<html></html>")
    #expect(input.promptMessages.map(\.role) == [.tool])
    #expect(rawMessages[2]["tool_call_id"] as? String == RuntimeToolCallID.string(for: callID))
  }

  @Test
  func terminalFollowUpPromptIncludesEntireStructuredResultGroup() throws {
    let readCallID = UUID()
    let writeCallID = UUID()
    let turnID = UUID()
    let readArguments: ToolCallArguments = ["path": .string("README.md")]
    let writeArguments: ToolCallArguments = [
      "path": .string("movies.html"),
      "content": .string("<html></html>"),
    ]
    let entries = [
      try ModelFacingPromptRenderer.userPromptEntry(
        turnID: turnID,
        prompt: "read README.md and create movies.html"
      ),
      try ModelFacingPromptRenderer.assistantOutputEntry(
        turnID: turnID,
        content: [
          ToolCallModelMessage(
            rawRequest: RawToolCallRequest(
              id: readCallID,
              workspaceID: UUID(),
              sessionID: UUID(),
              toolName: .readFile,
              arguments: readArguments
            )
          ).modelContextContent,
          writeFileToolCall(callID: writeCallID, arguments: writeArguments).modelContextContent,
        ].joined(separator: "\n")
      ),
      try ModelFacingPromptRenderer.toolResultEntry(
        turnID: turnID,
        toolResult: ToolResultModelMessage(
          callID: readCallID,
          toolName: .readFile,
          payload: .readFile(
            .success(
              path: WorkspaceRelativePath(rawValue: "README.md"),
              content: ToolTextOutput(text: "Project overview")
            ))
        ),
        request: toolRequest(callID: readCallID, toolName: .readFile, arguments: readArguments),
        originalUserRequest: "read README.md and create movies.html"
      ),
      try ModelFacingPromptRenderer.toolResultEntry(
        turnID: turnID,
        toolResult: ToolResultModelMessage(
          callID: writeCallID,
          toolName: .writeFile,
          payload: .writeFile(
            .success(path: WorkspaceRelativePath(rawValue: "movies.html"), bytesWritten: 13))
        ),
        request: toolRequest(callID: writeCallID, toolName: .writeFile, arguments: writeArguments),
        originalUserRequest: "read README.md and create movies.html"
      ),
    ]

    let input = try generationInput(from: entries)

    #expect(input.history.map(\.role) == [.user, .assistant])
    #expect(
      input.historySnapshot[1].toolCalls.map(\.id) == [
        RuntimeToolCallID.string(for: readCallID),
        RuntimeToolCallID.string(for: writeCallID),
      ])
    #expect(input.promptMessages.map(\.role) == [.tool, .tool])
    #expect(input.promptMessages[0].content.contains("Project overview"))
    #expect(input.promptMessages[1].content.contains("Wrote 13 bytes to movies.html."))
    #expect(!input.promptMessages[1].content.contains("Original user request:"))
  }

  @Test
  func laterUserTurnHistoryKeepsStructuredToolResult() throws {
    let callID = UUID()
    let turnID = UUID()
    let transcript = ModelContextSnapshot(entries: [
      try ModelFacingPromptRenderer.userPromptEntry(turnID: turnID, prompt: "read README.md"),
      try ModelFacingPromptRenderer.assistantOutputEntry(
        turnID: turnID,
        content: toolCallContent(
          callID: callID,
          toolName: .readFile,
          arguments: ["path": .string("README.md")]
        )
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
        originalUserRequest: "read README.md"
      ),
      try ModelFacingPromptRenderer.assistantOutputEntry(
        turnID: turnID,
        content: "README.md is a project file."
      ),
      try ModelFacingPromptRenderer.userPromptEntry(prompt: "what did you read?"),
    ])

    let history = try GemmaHistoryRenderer.generationHistoryMessages(from: transcript)

    #expect(history.map(\.role) == [.user, .assistant, .tool, .assistant])
    #expect(history[2].content.contains("<observation"))
    #expect(history[2].content.contains("Project overview"))
    #expect(history[2].content.contains("Tool receipt:") == false)
    #expect(history[3].content.contains("README.md is a project file."))
  }

  // The native tool result is rendered as the same structured tool message in
  // both the prompt batch and later history, so the cached KV prefix survives
  // the turn boundary.
  @Test
  func cachePrefixSurvivesUserTurnAfterToolObservation() throws {
    let callID = UUID()
    let turnID = UUID()
    let toolTurnEntries = [
      try ModelFacingPromptRenderer.userPromptEntry(turnID: turnID, prompt: "read README.md"),
      try ModelFacingPromptRenderer.assistantOutputEntry(
        turnID: turnID,
        content: toolCallContent(
          callID: callID,
          toolName: .readFile,
          arguments: ["path": .string("README.md")]
        )
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
        originalUserRequest: "read README.md"
      ),
    ]

    // What the runtime caches after the tool follow-up completes:
    // history before the prompt + structured prompt batch + assistant(output).
    let followUpInput = try generationInput(from: toolTurnEntries)
    let cachedPrefix =
      followUpInput.historySnapshot
      + followUpInput.promptSnapshot
      + [
        GemmaMessageSnapshot(
          role: Chat.Message.Role.assistant.rawValue,
          content: "README.md is a project file."
        )
      ]

    // The next user turn: the observation now lives in history in the same
    // structured tool form that was sent as the prompt.
    let nextTurn = ModelContextSnapshot(
      entries: toolTurnEntries + [
        try ModelFacingPromptRenderer.assistantOutputEntry(
          turnID: turnID, content: "README.md is a project file."),
        try ModelFacingPromptRenderer.userPromptEntry(prompt: "what did you read?"),
      ])
    let currentHistory = try GemmaHistoryRenderer.generationInput(from: nextTurn).historySnapshot

    // Same position, same wire form: the prefilled structured tool result is
    // identical to its later history rendering.
    #expect(cachedPrefix.map(\.role) == ["user", "assistant", "tool", "assistant"])
    #expect(cachedPrefix[1].toolCalls.count == 1)
    #expect(cachedPrefix[2].toolCallID == RuntimeToolCallID.string(for: callID))
    #expect(cachedPrefix[2].content.contains("<observation"))
    #expect(currentHistory[2].content.contains("<observation"))
    #expect(cachedPrefix[2] == currentHistory[2])
    #expect(cachedPrefix == currentHistory)
    #expect(GemmaSessionCachePolicy.isPrefix(cachedPrefix, of: currentHistory))
    #expect(
      GemmaSessionCachePolicy.firstMismatchIndex(
        cachedPrefix: cachedPrefix,
        currentHistory: currentHistory
      ) == nil)
  }

  @Test
  func cachePrefixSurvivesTerminalWriteFollowUpBoundary() throws {
    let readCallID = UUID()
    let writeCallID = UUID()
    let turnID = UUID()
    let originalPrompt = "read README.md and write summary.txt"
    let readArguments: ToolCallArguments = ["path": .string("README.md")]
    let writeArguments: ToolCallArguments = [
      "path": .string("summary.txt"),
      "content": .string("Project summary"),
    ]
    let entriesBeforeWriteResult = [
      try ModelFacingPromptRenderer.userPromptEntry(turnID: turnID, prompt: originalPrompt),
      try ModelFacingPromptRenderer.assistantOutputEntry(
        turnID: turnID,
        content: toolCallContent(
          callID: readCallID,
          toolName: .readFile,
          arguments: readArguments
        )
      ),
      try ModelFacingPromptRenderer.toolResultEntry(
        turnID: turnID,
        toolResult: ToolResultModelMessage(
          callID: readCallID,
          toolName: .readFile,
          payload: .readFile(
            .success(
              path: WorkspaceRelativePath(rawValue: "README.md"),
              content: ToolTextOutput(text: "Project overview")
            ))
        ),
        request: toolRequest(callID: readCallID, toolName: .readFile, arguments: readArguments),
        originalUserRequest: originalPrompt
      ),
    ]
    let writeRequest = toolRequest(
      callID: writeCallID,
      toolName: .writeFile,
      arguments: writeArguments
    )
    let writeBoundary = try ModelFacingPromptRenderer.assistantOutputEntry(
      turnID: turnID,
      content: toolCallContent(
        callID: writeCallID,
        toolName: .writeFile,
        arguments: writeArguments
      )
    )

    let writeGenerationInput = try generationInput(from: entriesBeforeWriteResult)
    let cachedPrefix =
      writeGenerationInput.historySnapshot
      + writeGenerationInput.promptSnapshot
      + [
        GemmaMessageSnapshot(
          role: Chat.Message.Role.assistant.rawValue,
          content: "",
          toolCalls: [
            GemmaToolCallSnapshot(
              id: RuntimeToolCallID.string(for: writeCallID),
              name: ToolName.writeFile.rawValue,
              arguments: writeArguments
            )
          ]
        )
      ]
    let currentHistory = try generationInput(
      from: entriesBeforeWriteResult + [
        writeBoundary,
        try ModelFacingPromptRenderer.toolResultEntry(
          turnID: turnID,
          toolResult: ToolResultModelMessage(
            callID: writeCallID,
            toolName: .writeFile,
            payload: .writeFile(
              .success(path: WorkspaceRelativePath(rawValue: "summary.txt"), bytesWritten: 15))
          ),
          request: writeRequest,
          originalUserRequest: originalPrompt
        ),
      ]
    ).historySnapshot

    #expect(cachedPrefix.map(\.role) == ["user", "assistant", "tool", "assistant"])
    #expect(currentHistory[3].toolCalls.map(\.id) == [RuntimeToolCallID.string(for: writeCallID)])
    #expect(cachedPrefix == currentHistory)
    #expect(GemmaSessionCachePolicy.isPrefix(cachedPrefix, of: currentHistory))
    #expect(
      GemmaSessionCachePolicy.firstMismatchIndex(
        cachedPrefix: cachedPrefix,
        currentHistory: currentHistory
      ) == nil)
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
        prompt: "create movies.html"
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
        followUpInstruction: finalToolResultInstruction,
        originalUserRequest: "create movies.html"
      ),
    ]
    let (history, prompt) = try generationHistoryAndPrompt(from: entries)

    #expect(history.map(\.role) == [.user, .assistant])
    #expect(prompt.role == .tool)
    #expect(!prompt.content.contains("Original user request:"))
    #expect(prompt.content.contains("Summary: Wrote 13 bytes to movies.html."))
    #expect(prompt.content.contains("Do not include generated file contents"))
    #expect(!prompt.content.contains("No more tools may run in this response."))
  }

  @Test
  func cacheTraceReportsAppendOnlyDelta() {
    let prefix = GemmaHistoryRenderer.messageSnapshot(from: [
      .user("hello"),
      .assistant("hi"),
    ])
    let appendedHistory = GemmaHistoryRenderer.messageSnapshot(from: [
      .user("hello"),
      .assistant("hi"),
      .tool("result", id: "call_1"),
    ])
    let identity = GemmaSessionCachePolicy.cacheIdentity(
      systemPrompt: "Use concise coding steps.",
      settings: .agentDefault,
      projectionMode: .fullHistory
    )

    let trace = GemmaSessionCachePolicy.trace(
      mode: .appendDelta,
      reason: .appendOnlyDelta,
      currentHistory: appendedHistory,
      currentIdentity: identity,
      cachedPrefix: prefix,
      cachedIdentity: identity,
      appendOnly: GemmaSessionCachePolicy.isPrefix(prefix, of: appendedHistory),
      mismatchReason: nil,
      firstMismatchIndex: nil
    )

    #expect(trace.cacheMode == .appendDelta)
    #expect(trace.cacheReason == .appendOnlyDelta)
    #expect(trace.appendOnly)
    #expect(trace.reusedMessageCount == 2)
    #expect(trace.appendedMessageCount == 1)
    #expect(trace.mismatchReason == nil)
  }

  @Test
  func cacheTraceReportsHistoryMismatch() {
    let prefix = GemmaHistoryRenderer.messageSnapshot(from: [
      .user("hello"),
      .assistant("hi"),
    ])
    let changedHistory = GemmaHistoryRenderer.messageSnapshot(from: [
      .user("hello"),
      .assistant("different"),
    ])
    let identity = GemmaSessionCachePolicy.cacheIdentity(
      systemPrompt: "Use concise coding steps.",
      settings: .agentDefault,
      projectionMode: .fullHistory
    )

    let trace = GemmaSessionCachePolicy.trace(
      mode: .dirtyRebuild,
      reason: .historyChanged,
      currentHistory: changedHistory,
      currentIdentity: identity,
      cachedPrefix: prefix,
      cachedIdentity: identity,
      appendOnly: GemmaSessionCachePolicy.isPrefix(prefix, of: changedHistory),
      mismatchReason: "history_changed",
      firstMismatchIndex: GemmaSessionCachePolicy.firstMismatchIndex(
        cachedPrefix: prefix,
        currentHistory: changedHistory
      )
    )

    #expect(trace.cacheMode == .dirtyRebuild)
    #expect(trace.cacheReason == .historyChanged)
    #expect(!trace.appendOnly)
    #expect(trace.mismatchReason == "history_changed")
    #expect(trace.firstMismatchIndex == 1)
  }

  @Test
  func cacheInvalidationReasonsMapToDirtyRebuildReasons() {
    #expect(
      GemmaSessionCacheReason.generationInvalidationReason(from: .cancelled)
        == .invalidatedGenCancelled)
    #expect(
      GemmaSessionCacheReason.generationInvalidationReason(from: .interrupted)
        == .invalidatedGenInterrupted)
    #expect(
      GemmaSessionCacheReason.generationInvalidationReason(from: .downstreamTerminated)
        == .invalidatedGenDownstreamTerminated)
    #expect(
      GemmaSessionCacheReason.generationInvalidationReason(from: .runtimeError)
        == .invalidatedGenRuntimeError)
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
    var plan: GemmaModelStreamPlan? = GemmaModelStreamProcessor.modelStreamPlan(
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
    #expect(GemmaModelStreamProcessor.memoryClearReason(for: .completed) == nil)
    #expect(GemmaModelStreamProcessor.memoryClearReason(for: .downstreamTerminated) == nil)
    #expect(GemmaModelStreamProcessor.memoryClearReason(for: .cancelled) == nil)
    #expect(GemmaModelStreamProcessor.memoryClearReason(for: .nativeToolCallBoundary) == nil)
    #expect(GemmaModelStreamProcessor.memoryClearReason(for: .runtimeError) == .runtimeError)
    #expect(
      GemmaModelStreamProcessor.memoryClearReason(for: .interruptedStream) == .interruptedStream)
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
    let stream = GemmaModelStreamProcessor.modelStream(
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
  func thoughtChannelParserSplitsThoughtBlocksAcrossChunks() {
    var parser = GemmaThoughtChannelParser()

    let segments = [
      parser.append("<|chan"),
      parser.append("nel|>thought The user said hey."),
      parser.append(" I should greet them.<chan"),
      parser.append("nel|>Hello"),
      parser.append(" there."),
      parser.finish(),
    ].flatMap { $0 }

    #expect(
      segments == [
        .thinking(" The user said hey."),
        .thinking(" I should greet them."),
        .visible("Hello"),
        .visible(" there."),
      ])
  }

  @Test
  func thoughtChannelParserSupportsAsymmetricThoughtMarker() {
    var parser = GemmaThoughtChannelParser()

    let segments = [
      parser.append("<|chan"),
      parser.append("nel>thought I should answer."),
      parser.append("<channel|>Done."),
      parser.finish(),
    ].flatMap { $0 }

    #expect(
      segments == [
        .thinking(" I should answer."),
        .visible("Done."),
      ])
  }

  @Test
  func modelStreamSeparatesThoughtChannelChunks() async throws {
    let memoryClearRecorder = GemmaMemoryClearRecorder()
    let completionRecorder = GemmaStreamCompletionRecorder()
    let source = AsyncThrowingStream<Generation, Error> { continuation in
      continuation.yield(.chunk("<|channel>thought"))
      continuation.yield(.chunk(" The user said hey."))
      continuation.yield(.chunk("<channel|>Hello"))
      continuation.yield(.chunk(" there."))
      continuation.yield(
        .info(
          GenerateCompletionInfo(
            promptTokenCount: 8,
            generationTokenCount: 8,
            promptTime: 0.1,
            generationTime: 0.1
          )
        ))
      continuation.finish()
    }
    let stream = GemmaModelStreamProcessor.modelStream(
      from: source,
      traceID: UUID(),
      traceMetadata: nil,
      cacheTrace: defaultCacheTrace(),
      markCompleted: { output in
        await completionRecorder.record(output)
      },
      markCancelled: { _ in },
      memoryCacheClearer: GemmaMemoryCacheClearer { reason in
        await memoryClearRecorder.record(reason)
      }
    )

    var chunks: [String] = []
    var thinkingChunks: [String] = []
    var iterator = stream.makeAsyncIterator()
    while let event = try await iterator.next() {
      switch event {
      case .chunk(let chunk):
        chunks.append(chunk)
      case .thinkingChunk(let chunk):
        thinkingChunks.append(chunk)
      case .toolCall, .completed:
        break
      }
    }

    #expect(chunks.joined() == "Hello there.")
    #expect(thinkingChunks.joined() == " The user said hey.")
    #expect(await completionRecorder.firstOutput == "Hello there.")
    #expect(await memoryClearRecorder.reasons.isEmpty)
  }

  @Test
  func cancellationModelStreamDoesNotClearMemoryCache() async throws {
    let memoryClearRecorder = GemmaMemoryClearRecorder()
    let source = AsyncThrowingStream<Generation, Error> { continuation in
      continuation.yield(.chunk("partial"))
      continuation.finish(throwing: CancellationError())
    }
    let stream = GemmaModelStreamProcessor.modelStream(
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
    let stream = GemmaModelStreamProcessor.modelStream(
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
    let stream = GemmaModelStreamProcessor.modelStream(
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
    let stream = GemmaModelStreamProcessor.modelStream(
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
  func modelStreamNormalizesDuplicateNativeToolCallIDs() async throws {
    let boundaryRecorder = GemmaNativeBoundaryRecorder()
    let duplicateID = "call_0123456789ABCDEF0123456789ABCDEF"
    let firstToolCall = MLXLMCommon.ToolCall(
      function: .init(name: "read_file", arguments: ["path": "README.md"]),
      id: duplicateID
    )
    let secondToolCall = MLXLMCommon.ToolCall(
      function: .init(name: "list_files", arguments: ["path": "."]),
      id: duplicateID
    )
    let source = AsyncThrowingStream<Generation, Error> { continuation in
      continuation.yield(.toolCall(firstToolCall))
      continuation.yield(.toolCall(secondToolCall))
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
    let stream = GemmaModelStreamProcessor.modelStream(
      from: source,
      traceID: UUID(),
      traceMetadata: nil,
      cacheTrace: defaultCacheTrace(),
      markCompleted: { _ in },
      markNativeToolCallBoundary: { output, nativeToolCalls in
        await boundaryRecorder.record(output: output, nativeToolCalls: nativeToolCalls)
      },
      markCancelled: { _ in }
    )

    var iterator = stream.makeAsyncIterator()
    let firstEvent = try await iterator.next()
    let secondEvent = try await iterator.next()
    guard case .toolCall(let firstRuntimeToolCall) = firstEvent,
      case .toolCall(let secondRuntimeToolCall) = secondEvent
    else {
      Issue.record("Expected two native tool call events.")
      return
    }
    _ = try await iterator.next()
    try await waitUntilAsync {
      await boundaryRecorder.firstBoundary?.nativeToolCalls.count == 2
    }

    #expect(firstRuntimeToolCall.id == "call_0123456789abcdef0123456789abcdef")
    #expect(secondRuntimeToolCall.id != firstRuntimeToolCall.id)
    #expect(RuntimeToolCallID.uuid(from: secondRuntimeToolCall.id) != nil)
    #expect(
      await boundaryRecorder.firstBoundary?.nativeToolCalls.map(\.id)
        == [firstRuntimeToolCall.id, secondRuntimeToolCall.id])
  }

  @Test
  func nativeGemma4ToolContextMapsRegistryToMLXToolSpecs() throws {
    let toolContext = ChatRuntimeToolContext(
      strategy: .nativeGemma4,
      registry: ToolExecutorRegistry.readOnly.toolRegistry
    )

    let specs = try #require(GemmaNativeToolSchema.toolSpecs(from: toolContext))
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

    let specs = try #require(GemmaNativeToolSchema.toolSpecs(from: toolContext))
    let todoSpec = try #require(
      specs.first { spec in
        let function = spec["function"] as? [String: any Sendable]
        return function?["name"] as? String == "todo_write"
      })
    let function = try #require(todoSpec["function"] as? [String: any Sendable])
    let parameters = try #require(function["parameters"] as? [String: any Sendable])
    let properties = try #require(parameters["properties"] as? [String: any Sendable])
    let item1 = try #require(properties["item1"] as? [String: any Sendable])
    let item2 = try #require(properties["item2"] as? [String: any Sendable])
    let done1 = try #require(properties["done1"] as? [String: any Sendable])
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

    #expect(item1["type"] as? String == "string")
    #expect(item1["items"] == nil)
    #expect(item2["type"] as? String == "string")
    #expect(item2["items"] == nil)
    #expect(done1["type"] as? String == "boolean")
    #expect(done1["items"] == nil)
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

    let runtimeToolCall = GemmaNativeToolSchema.chatRuntimeToolCall(from: mlxToolCall)

    #expect(runtimeToolCall.name == "read_file")
    #expect(runtimeToolCall.arguments["path"] == .string("README.md"))
    #expect(runtimeToolCall.arguments["limit"] == .number(20))
    #expect(runtimeToolCall.arguments["include_hidden"] == .bool(false))
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
    let stream = GemmaModelStreamProcessor.modelStream(
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
  ) -> [ProjectedModelContextEntry] {
    ModelContextSnapshot(entries: entries)
      .projectedEntries(mode: GemmaHistoryRenderer.runtimeProjectionMode)
  }

  private func generationInput(
    from entries: [ModelContextEntry]
  ) throws -> GemmaGenerationInput {
    try GemmaHistoryRenderer.generationInput(from: ModelContextSnapshot(entries: entries))
  }

  private func generationHistoryAndPrompt(
    from entries: [ModelContextEntry]
  ) throws -> (history: [Chat.Message], prompt: Chat.Message) {
    let projectedEntries = projectedEntries(from: entries)
    let lastPromptIndex = try #require(
      projectedEntries.lastIndex { $0.role == .user || $0.role == .tool }
    )
    let history = try GemmaHistoryRenderer.generationHistoryMessages(
      from: projectedEntries[..<lastPromptIndex]
    )
    let prompt = GemmaHistoryRenderer.chatMessage(from: projectedEntries[lastPromptIndex])
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

  private func toolCallContent(
    callID: UUID,
    toolName: ToolName,
    arguments: ToolCallArguments
  ) -> String {
    ToolCallModelMessage(
      rawRequest: RawToolCallRequest(
        id: callID,
        workspaceID: UUID(),
        sessionID: UUID(),
        toolName: toolName,
        arguments: arguments
      )
    ).modelContextContent
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
      cacheMode: .newSession,
      cacheReason: .newSessionNoCache,
      contextSignature: "context",
      previousContextSignature: nil,
      appendOnly: false,
      reusedMessageCount: 0,
      appendedMessageCount: 0,
      mismatchReason: nil,
      firstMismatchIndex: nil,
      systemPromptChanged: nil,
      currentPromptContextChanged: nil
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

private actor GemmaStreamCompletionRecorder {
  private var outputs: [String] = []

  var firstOutput: String? {
    outputs.first
  }

  func record(_ output: String) {
    outputs.append(output)
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
