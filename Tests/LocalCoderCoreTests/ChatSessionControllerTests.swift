import Foundation
import Testing

@testable import LocalCoderCore

@Suite(.serialized)
@MainActor
struct ChatSessionControllerTests {
  @Test
  func canSendRequiresReadyModelNonEmptyDraftAndIdleGeneration() {
    let controller = ChatSessionController(
      runtime: ChatSessionFakeChatModelRuntime(),
      modelPath: "/tmp/model"
    )

    controller.modelRuntime.modelState = .ready
    controller.draft = "  hello  "

    #expect(controller.canSend)

    controller.draft = "   "
    #expect(!controller.canSend)

    controller.draft = "hello"
    controller.isGenerating = true
    #expect(!controller.canSend)
  }

  @Test
  func loadSessionAndSnapshotPreserveFocusedFileState() {
    let path = WorkspaceRelativePath(rawValue: "README.md")
    let focusedFileState = FocusedFileState(
      activePath: path,
      recentPaths: [
        FocusedPath(path: path, source: .readFile, confidence: .active)
      ]
    )
    let session = ChatSession(
      selectedModelID: ManagedModelCatalog.defaultModelID,
      focusedFileState: focusedFileState,
      systemPrompt: "System",
      generationSettings: .codingDefault,
      interactionMode: .agent
    )
    let controller = ChatSessionController(
      runtime: ChatSessionFakeChatModelRuntime(),
      modelPath: "/tmp/model"
    )

    controller.loadSession(session)
    let snapshot = controller.sessionSnapshot(updating: session)

    #expect(controller.chatSession.focusedFileState == focusedFileState)
    #expect(controller.chatSession.interactionMode == .agent)
    #expect(snapshot.focusedFileState == focusedFileState)
    #expect(snapshot.interactionMode == .agent)
  }

  @Test
  func loadSessionClearsRuntimeContextWhenModelIsReused() async throws {
    let runtime = CountingClearContextRuntime()
    let session = ChatSession(
      selectedModelID: ManagedModelCatalog.defaultModelID,
      systemPrompt: "System",
      generationSettings: .codingDefault,
      interactionMode: .agent
    )
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready

    controller.loadSession(session)

    try await waitUntilAsync { await runtime.clearContextCount == 1 }
  }

  @Test
  func loadSessionDoesNotClearRuntimeContextWhileModelIsLoading() async throws {
    let runtime = CountingClearContextRuntime()
    let session = ChatSession(
      selectedModelID: ManagedModelCatalog.defaultModelID,
      systemPrompt: "System",
      generationSettings: .codingDefault,
      interactionMode: .agent
    )
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .loading

    controller.loadSession(session)
    await Task.yield()

    #expect(await runtime.clearContextCount == 0)
  }

  @Test
  func defaultsToChatInteractionMode() {
    let controller = ChatSessionController(
      runtime: ChatSessionFakeChatModelRuntime(),
      modelPath: "/tmp/model"
    )

    #expect(controller.chatSession.interactionMode == .chat)
  }

  @Test
  func loadSessionForExperimentalGemma4PreservesToolMode() {
    let session = ChatSession(
      selectedModelID: "gemma4-e2b",
      interactionMode: .agent
    )
    let controller = ChatSessionController(
      runtime: ChatSessionFakeChatModelRuntime(),
      modelPath: "/tmp/model"
    )

    controller.loadSession(session)

    #expect(controller.modelRuntime.selectedModelID == "gemma4-e2b")
    #expect(controller.chatSession.interactionMode == .agent)
    #expect(controller.errorMessage == nil)
  }

  @Test
  func setInteractionModeAllowsExperimentalGemma4ToolModes() {
    let session = ChatSession(selectedModelID: "gemma4-e2b")
    let controller = ChatSessionController(
      runtime: ChatSessionFakeChatModelRuntime(),
      modelPath: "/tmp/model"
    )
    controller.loadSession(session)

    controller.setInteractionMode(.agent)

    #expect(controller.chatSession.interactionMode == .agent)
    #expect(controller.errorMessage == nil)
  }

  @Test
  func sendMessageAllowsExperimentalGemma4PersistedToolMode() async throws {
    let runtime = ChatSessionFakeChatModelRuntime(chunks: ["native mode response"])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.loadSession(ChatSession(selectedModelID: "gemma4-e2b"))
    controller.chatSession.interactionMode = .agent
    controller.modelRuntime.modelState = .ready
    controller.draft = "inspect files"

    controller.sendMessage()
    try await waitUntil { !controller.isGenerating }

    #expect(controller.draft == "")
    #expect(!controller.chatSession.turns.isEmpty)
    #expect(controller.errorMessage == nil)
  }

  @Test
  func setInteractionModeClearsRuntimeContext() async throws {
    let runtime = CountingClearContextRuntime()
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")

    controller.setInteractionMode(.agent)

    try await waitUntilAsync { await runtime.clearContextCount == 1 }
  }

  @Test
  func sendMessageWaitsForPendingRuntimeContextClear() async throws {
    let runtime = DelayedClearContextRuntime()
    defer { Task { await runtime.releaseClearContext() } }
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready

    controller.setInteractionMode(.agent)
    try await waitUntilAsync { await runtime.didStartClearContext }

    controller.draft = "hello"
    controller.sendMessage()
    await Task.yield()

    #expect(await runtime.streamReplyCount == 0)

    await runtime.releaseClearContext()

    try await waitUntilAsync { await runtime.streamReplyCount == 1 }
    try await waitUntil { !controller.isGenerating }
  }

  @Test
  func sendMessageStreamsAssistantReplyAndClearsDraftAndAttachments() async throws {
    let attachment = ChatAttachment(
      url: URL(filePath: "/tmp/source.swift"),
      displayName: "source.swift",
      kind: .text,
      content: "let value = 1"
    )
    let runtime = ChatSessionFakeChatModelRuntime(chunks: ["hello", " world"])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.draft = "Explain this"
    controller.chatSession.pendingAttachments = [attachment]

    controller.sendMessage()

    try await waitUntil { !controller.isGenerating }

    #expect(controller.draft.isEmpty)
    #expect(controller.chatSession.pendingAttachments.isEmpty)
    #expect(controller.chatSession.testMessages.count == 2)
    #expect(controller.chatSession.testMessages[0].kind == .user)
    #expect(controller.chatSession.testMessages[0].content == "Explain this")
    #expect(controller.chatSession.testMessages[0].attachments == [attachment])
    #expect(controller.chatSession.testMessages[1].kind == .assistant)
    #expect(controller.chatSession.testMessages[1].content == "hello world")
    #expect(controller.chatSession.testMessages[1].deliveryStatus == .complete)
    #expect(
      controller.chatSession.focusedFileState.activePath
        == WorkspaceRelativePath(rawValue: "source.swift"))
    #expect(controller.chatSession.focusedFileState.recentPaths.first?.source == .attachment)
    #expect(
      controller.chatSession.focusedFileState.snapshots[
        WorkspaceRelativePath(rawValue: "source.swift")]?.excerpt == "let value = 1")
    #expect(controller.chatSession.turns.count == 1)
    #expect(controller.chatSession.turns[0].status == .completed)
    #expect(controller.chatSession.turns[0].modelContextPolicy == .included)
    #expect(
      controller.chatSession.turns[0].items.map(messageID)
        == controller.chatSession.testMessages.map(\.id)
    )
    let generationMetrics = try #require(controller.chatSession.testMessages[1].generationMetrics)
    #expect(generationMetrics.generatedTokenCount == 2)
    #expect(generationMetrics.tokensPerSecond == 100)
    #expect(generationMetrics.durationMs > 0)
    let capturedMessages = await runtime.capturedMessages
    #expect(await runtime.capturedAttachments == [[attachment]])
    #expect(
      capturedMessages.first?.contains(where: { message in
        message.role == .user && message.content.contains("Attached file: source.swift")
      }) == true)
    #expect(
      controller.chatSession.modelContextSnapshot.entries.map(\.frozenContent.role) == [
        .user, .assistant,
      ])
    #expect(
      controller.chatSession.modelContextSnapshot.entries[0].frozenContent.content.contains(
        "Attached file: source.swift"))
    #expect(
      controller.chatSession.modelContextSnapshot.entries[0].frozenContent.content.contains(
        "Attached content excerpt:"))
    #expect(
      controller.chatSession.modelContextSnapshot.entries[0].frozenContent.content.contains(
        "Attached context:") == false)
    #expect(
      controller.chatSession.modelContextSnapshot.entries[0].frozenContent.content.contains(
        "Explain this"))
    if case .userPrompt(let context) = controller.chatSession.modelContextSnapshot.entries[0].body {
      #expect(context.attachmentNames == [attachment.displayName])
      guard case .selected(let selection) = context.currentPromptContext,
        case .attachedFile(let attachedFile) = selection.blocks.values[0]
      else {
        Issue.record("Expected typed attached file current prompt context.")
        return
      }
      #expect(attachedFile.path == WorkspaceRelativePath(rawValue: "source.swift"))
      #expect(attachedFile.displayName == "source.swift")
      #expect(attachedFile.excerpt?.text == "let value = 1")
    } else {
      Issue.record("Expected first model-facing entry to be a user prompt.")
    }
    #expect(
      controller.chatSession.modelContextSnapshot.entries[1].frozenContent.content == "hello world"
    )
  }

  @Test
  func sendMessageForVisionModelForwardsImageAttachmentsToRuntime() async throws {
    let attachment = ChatAttachment(
      url: URL(filePath: "/tmp/screenshot.png"),
      displayName: "screenshot.png",
      kind: .image,
      content: "[Image attachment: screenshot.png, image/png, 128 bytes]",
      metadata: ChatAttachmentMetadata(
        mimeType: "image/png",
        byteCount: 128
      )
    )
    let runtime = ChatSessionFakeChatModelRuntime(chunks: ["looks like a screenshot"])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.loadSession(ChatSession(selectedModelID: "gemma4-e4b"))
    controller.modelRuntime.modelState = .ready
    controller.draft = "What is in this screenshot?"
    controller.chatSession.pendingAttachments = [attachment]

    controller.sendMessage()

    try await waitUntil { !controller.isGenerating }

    #expect(await runtime.capturedAttachments == [[attachment]])
    #expect(controller.chatSession.pendingAttachments.isEmpty)
    #expect(controller.chatSession.testMessages[0].attachments == [attachment])
  }

  @Test
  func cancelGenerationStopsControllerAndDropsTransientAssistantPlaceholder() async throws {
    let runtime = NonCooperativeStreamingRuntime(chunks: ["late reply"])
    defer { Task { await runtime.releaseChunks() } }
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.draft = "Cancel this"

    controller.sendMessage()

    try await waitUntilAsync { await runtime.didStartStreaming }
    controller.cancelGeneration()
    await runtime.releaseChunks()

    try await waitUntilAsync { await runtime.didFinishStreaming }
    try await waitUntil { !controller.isGenerating }

    #expect(!controller.isGenerating)
    #expect(controller.chatSession.testMessages.count == 1)
    #expect(controller.chatSession.testMessages.first?.kind == .user)
    #expect(controller.chatSession.testMessages.first?.content == "Cancel this")
    #expect(controller.chatSession.turns.count == 1)
    #expect(controller.chatSession.turns[0].status == .cancelled)
    #expect(controller.chatSession.turns[0].modelContextPolicy == .excluded)
    #expect(
      controller.chatSession.turns[0].items.map(messageID)
        == [controller.chatSession.testMessages[0].id])
    #expect(controller.errorMessage == nil)
  }

  @Test
  func failedStreamWithPartialOutputDoesNotLeaveAssistantMessageStreaming() async throws {
    let runtime = PartialFailingStreamingRuntime(chunks: ["partial answer"])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.draft = "fail after partial output"

    controller.sendMessage()

    try await waitUntil { !controller.isGenerating }

    #expect(controller.chatSession.turns.count == 1)
    #expect(controller.chatSession.turns[0].status == .failed)
    #expect(controller.chatSession.turns[0].modelContextPolicy == .excluded)
    #expect(controller.chatSession.testMessages.count == 2)
    #expect(controller.chatSession.testMessages[1].kind == .assistant)
    #expect(controller.chatSession.testMessages[1].content == "partial answer")
    #expect(controller.chatSession.testMessages[1].deliveryStatus == .cancelled)
    #expect(
      controller.errorMessage
        == ChatSessionFakeChatModelRuntimeError.streamFailed.localizedDescription)
  }

  @Test
  func interruptedStreamDoesNotLeaveAssistantMessageStreaming() async throws {
    let runtime = InterruptedStreamingRuntime(chunks: [])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.draft = "stream ends without completion"

    controller.sendMessage()

    try await waitUntil { !controller.isGenerating }

    #expect(controller.chatSession.turns.count == 1)
    #expect(controller.chatSession.turns[0].status == .failed)
    #expect(controller.chatSession.turns[0].modelContextPolicy == .excluded)
    #expect(controller.chatSession.testMessages.count == 1)
    #expect(controller.chatSession.testMessages[0].kind == .user)
    #expect(controller.errorMessage == ChatGenerationError.streamInterrupted.localizedDescription)
  }

  @Test
  func cancelAfterToolResultKeepsAuditButExcludesCancelledTurnFromNextPrompt() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ControlledStreamingRuntime(
      eventTurns: [
        [
          .toolCall(
            ChatRuntimeToolCall(
              name: "read_file",
              arguments: ["path": .string("README.md")]
            ))
        ],
        [.chunk("This follow-up should be cancelled.")],
        [.chunk("Yes, I'm here.")],
      ],
      blockedCallIndexes: [1]
    )
    defer { Task { await runtime.releaseStream(callIndex: 1) } }
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.setInteractionMode(.agent)
    controller.draft = "read README.md before answering"

    controller.sendMessage(in: workspace, sessionID: sessionID)
    try await waitUntilAsync { await runtime.startedStreamCount == 2 }
    try await waitUntil { controller.chatSession.testMessages.contains { $0.kind == .toolResult } }

    controller.cancelGeneration()
    await runtime.releaseStream(callIndex: 1)
    try await waitUntil { !controller.isGenerating }

    #expect(controller.chatSession.toolCalls.count == 1)
    #expect(controller.chatSession.toolCalls[0].status == .completed)
    #expect(controller.chatSession.testMessages.contains { $0.kind == .toolCall })
    #expect(controller.chatSession.testMessages.contains { $0.kind == .toolResult })
    #expect(controller.chatSession.turns.count == 1)
    #expect(controller.chatSession.turns[0].status == .cancelled)
    #expect(controller.chatSession.turns[0].modelContextPolicy == .excluded)

    controller.draft = "are you there"
    controller.sendMessage(in: workspace, sessionID: sessionID)
    try await waitUntil { !controller.isGenerating }

    let capturedMessages = await runtime.capturedMessages
    #expect(capturedMessages.count == 3)
    #expect(capturedMessages[2].contains(where: { $0.content.contains("read README") }) == false)
    #expect(capturedMessages[2].contains(where: { $0.content.contains("are you there") }))
  }

  @Test
  func staleCancelledStreamDoesNotResetNewTurnGenerationState() async throws {
    let runtime = ControlledStreamingRuntime(
      turns: [
        ["late first answer"],
        ["second answer"],
      ],
      blockedCallIndexes: [0, 1]
    )
    defer {
      Task {
        await runtime.releaseStream(callIndex: 0)
        await runtime.releaseStream(callIndex: 1)
      }
    }
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.draft = "first"

    controller.sendMessage()
    try await waitUntilAsync { await runtime.startedStreamCount == 1 }
    controller.cancelGeneration()

    controller.draft = "second"
    controller.sendMessage()
    try await waitUntilAsync { await runtime.startedStreamCount == 2 }

    await runtime.releaseStream(callIndex: 0)
    try await waitUntilAsync { await runtime.completedCallIndexes.contains(0) }
    #expect(controller.isGenerating)
    #expect(controller.chatSession.turns.count == 2)
    #expect(controller.chatSession.turns[0].status == .cancelled)
    #expect(controller.chatSession.turns[1].status == .running)

    await runtime.releaseStream(callIndex: 1)
    try await waitUntil { !controller.isGenerating }
    #expect(controller.chatSession.turns[1].status == .completed)
    #expect(controller.chatSession.testMessages.last?.content == "second answer")
  }

  @Test
  func sendMessageInWorkspaceKeepsNormalChatFreeOfToolExecutionWithoutAction() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(chunks: ["a short poem"])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.draft = "write a short poem"

    controller.sendMessage(in: workspace, sessionID: sessionID)

    try await waitUntil { !controller.isGenerating }

    #expect(controller.errorMessage == nil)
    #expect(controller.chatSession.toolCalls.isEmpty)
    #expect(controller.chatSession.testMessages.count == 2)
    #expect(controller.chatSession.testMessages[1].content == "a short poem")

    let capturedSystemPrompts = await runtime.capturedSystemPrompts
    #expect(capturedSystemPrompts.count == 1)
    #expect(!capturedSystemPrompts[0].contains("read_file"))
    #expect(!capturedSystemPrompts[0].contains("list_files"))
    #expect(!capturedSystemPrompts[0].contains("Available tools:"))

    let capturedContextUsageSystemPrompts = await runtime.capturedContextUsageSystemPrompts
    #expect(!capturedContextUsageSystemPrompts.contains { $0.contains("Available tools:") })
    #expect(!capturedContextUsageSystemPrompts.contains { $0.contains("read_file") })
  }

  @Test
  func agentModeInWorkspaceIncludesToolsForNonKeywordCodingPrompt() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(chunks: ["I will inspect the failure."])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.setInteractionMode(.agent)
    controller.draft = "Fix the failing test"

    controller.sendMessage(in: workspace, sessionID: sessionID)

    try await waitUntil { !controller.isGenerating }

    #expect(controller.errorMessage == nil)
    #expect(controller.chatSession.toolCalls.isEmpty)

    let capturedSystemPrompts = await runtime.capturedSystemPrompts
    #expect(capturedSystemPrompts.count == 1)
    #expect(capturedSystemPrompts[0].contains("Available tools:"))
    #expect(capturedSystemPrompts[0].contains("read_file"))
    #expect(capturedSystemPrompts[0].contains("edit_file"))
    #expect(capturedSystemPrompts[0].contains("write_file"))
  }

  @Test
  func sendMessageWithoutWorkspaceDoesNotExecuteAssistantAction() async throws {
    let runtime = ChatSessionFakeChatModelRuntime(chunks: [
      """
      <action name="read_file">
      <path>README.md</path>
      </action>
      """
    ])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.draft = "read README"

    controller.sendMessage()

    try await waitUntil { !controller.isGenerating }

    #expect(controller.errorMessage == nil)
    #expect(controller.chatSession.toolCalls.isEmpty)
    #expect(controller.chatSession.testMessages.count == 2)
    #expect(controller.chatSession.testMessages[1].kind == .assistant)
    #expect(controller.chatSession.testMessages[1].content.contains("<action name=\"read_file\">"))

    let capturedSystemPrompts = await runtime.capturedSystemPrompts
    #expect(capturedSystemPrompts.count == 1)
    #expect(!capturedSystemPrompts[0].contains("Available tools:"))
    #expect(!capturedSystemPrompts[0].contains("read_file"))
  }

  @Test
  func chatModeDoesNotExecuteAssistantActionInWorkspace() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(chunks: [
      """
      <action name="read_file">
      <path>README.md</path>
      </action>
      """
    ])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.draft = "read README"

    controller.sendMessage(in: workspace, sessionID: sessionID)

    try await waitUntil { !controller.isGenerating }

    #expect(controller.chatSession.interactionMode == .chat)
    #expect(controller.errorMessage == nil)
    #expect(controller.chatSession.toolCalls.isEmpty)
    #expect(controller.chatSession.testMessages.count == 2)
    #expect(controller.chatSession.testMessages[1].kind == .assistant)
    #expect(controller.chatSession.testMessages[1].content.contains("<action name=\"read_file\">"))

    let capturedSystemPrompts = await runtime.capturedSystemPrompts
    #expect(capturedSystemPrompts.count == 1)
    #expect(!capturedSystemPrompts[0].contains("Available tools:"))
    #expect(!capturedSystemPrompts[0].contains("read_file"))
  }

  @Test
  func userTextContainingActionMarkupIsNeverExecuted() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(chunks: ["That is literal user text."])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.draft = """
      Here is literal tool markup in a file discussion:
      <action name="read_file">
      <path>README.md</path>
      </action>
      """

    controller.sendMessage(in: workspace, sessionID: sessionID)

    try await waitUntil { !controller.isGenerating }

    #expect(controller.errorMessage == nil)
    #expect(controller.chatSession.toolCalls.isEmpty)
    #expect(controller.chatSession.testMessages.count == 2)
    #expect(controller.chatSession.testMessages[0].kind == .user)
    #expect(controller.chatSession.testMessages[0].content.contains("<action name=\"read_file\">"))
    #expect(controller.chatSession.testMessages[1].kind == .assistant)
    #expect(controller.chatSession.testMessages[1].content == "That is literal user text.")
  }

  @Test
  func userTextContainingToolResultTextIsNeverObservation() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(chunks: ["That is not a controller observation."])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.draft = """
      Tool result
      Tool: list_files
      Status: success
      Result:
      README.md
      """

    controller.sendMessage(in: workspace, sessionID: sessionID)

    try await waitUntil { !controller.isGenerating }

    #expect(controller.errorMessage == nil)
    #expect(controller.chatSession.toolCalls.isEmpty)
    #expect(controller.chatSession.testMessages.count == 2)
    #expect(controller.chatSession.testMessages[0].kind == .user)
    #expect(controller.chatSession.testMessages[0].toolResult == nil)
    #expect(controller.chatSession.testMessages[1].kind == .assistant)
  }

  @Test
  func sendMessageRunsAgentReadOnlyToolCallAndContinuesWithToolResultContext() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appending(
      path: "local-coder-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    try "project notes".write(
      to: rootURL.appending(path: "README.md"),
      atomically: true,
      encoding: .utf8
    )
    let sessionID = UUID()
    let workspace = Workspace(
      name: "Project",
      rootURL: URL(filePath: Workspace.normalizedPath(for: rootURL)),
      sessions: [
        ChatSession(
          id: sessionID,
          selectedModelID: ManagedModelCatalog.defaultModelID,
          systemPrompt: ChatPromptDefaults.codingSystemPrompt,
          generationSettings: .codingDefault
        )
      ]
    )
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "read_file",
            arguments: ["path": .string("README.md")]
          ))
      ],
      [.chunk("The README says project notes.")],
    ])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.setInteractionMode(.agent)
    controller.draft = "lies die projektbeschreibung"

    controller.sendMessage(in: workspace, sessionID: sessionID)

    try await waitUntil { !controller.isGenerating }

    #expect(controller.chatSession.toolCalls.count == 1)
    #expect(controller.chatSession.toolCalls[0].status == .completed)
    #expect(controller.chatSession.toolCalls[0].resultPreview?.text == "1: project notes")
    #expect(
      controller.chatSession.focusedFileState.activePath
        == WorkspaceRelativePath(rawValue: "README.md"))
    #expect(controller.chatSession.focusedFileState.recentPaths.first?.source == .readFile)
    #expect(
      controller.chatSession.focusedFileState.snapshots[
        WorkspaceRelativePath(rawValue: "README.md")]?.excerpt == "1: project notes")
    let callID = controller.chatSession.toolCalls[0].request.id
    #expect(controller.chatSession.testMessages.count == 4)
    #expect(controller.chatSession.testMessages[1].kind == .toolCall)
    #expect(controller.chatSession.testMessages[1].content.isEmpty)
    #expect(controller.chatSession.testMessages[1].toolCall?.callID == callID)
    #expect(controller.chatSession.testMessages[1].toolCall?.toolName == .readFile)
    #expect(controller.chatSession.testMessages[1].generationMetrics == nil)
    #expect(
      controller.chatSession.testMessages[1].toolCall?.arguments == [
        ToolCallModelArgument(name: "path", value: "README.md")
      ]
    )
    #expect(controller.chatSession.testMessages[2].kind == .toolResult)
    #expect(controller.chatSession.testMessages[2].content.isEmpty)
    #expect(controller.chatSession.testMessages[2].toolResult?.callID == callID)
    #expect(controller.chatSession.testMessages[2].toolResult?.toolName == .readFile)
    #expect(controller.chatSession.testMessages[2].toolResult?.preview.status == .success)
    #expect(controller.chatSession.testMessages[2].toolResult?.preview.text == "1: project notes")
    #expect(controller.chatSession.testMessages[3].content == "The README says project notes.")
    #expect(
      controller.chatSession.modelContextSnapshot.entries.map(\.frozenContent.role) == [
        .user, .assistant, .user, .assistant,
      ])
    #expect(
      controller.chatSession.modelContextSnapshot.entries[0].frozenContent.content
        .contains("lies die projektbeschreibung"))
    #expect(
      controller.chatSession.modelContextSnapshot.entries[1].frozenContent.content.contains(
        "<|tool_call>call:read_file")
    )
    #expect(
      controller.chatSession.modelContextSnapshot.entries[2].frozenContent.content.contains(
        "1: project notes"))
    #expect(
      controller.chatSession.modelContextSnapshot.entries[3].frozenContent.content
        == "The README says project notes.")

    let capturedMessages = await runtime.capturedMessages
    #expect(capturedMessages.count == 2)
    #expect(
      capturedMessages[1].last(where: { $0.role == .user })?.content.contains(
        "1: project notes"
      ) == true)
    #expect(
      capturedMessages[1].contains(where: { message in
        message.role == .user && message.content.contains("1: project notes")
      }))
    #expect(
      !capturedMessages[1].contains(where: { message in
        message.content.contains("Current focused file: README.md")
      }))
    let capturedSystemPrompts = await runtime.capturedSystemPrompts
    #expect(capturedSystemPrompts.count == 2)
    #expect(capturedSystemPrompts[0].contains("read_file"))
    #expect(capturedSystemPrompts[0].contains("list_files"))
    #expect(capturedSystemPrompts[0].contains("glob_files"))
    #expect(capturedSystemPrompts[0].contains("search_files"))
    #expect(capturedSystemPrompts[0].contains("write_file"))
    #expect(capturedSystemPrompts[0].contains("edit_file"))
    #expect(capturedSystemPrompts[1].contains("You received a tool result."))
    #expect(capturedSystemPrompts[1].contains("Available tools: read_file"))
    #expect(capturedSystemPrompts[1].contains("edit_file"))
    #expect(!capturedSystemPrompts[1].contains("Tool calling:"))
  }

  @Test
  func nativeReadFileFollowUpIncludesOriginalUserRequestAndToolObservation() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "read_file",
            arguments: ["path": .string("README.md")]
          ))
      ],
      [.chunk("The README says project notes.")],
    ])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.loadSession(
      ChatSession(
        id: sessionID,
        selectedModelID: "gemma4-e2b",
        interactionMode: .agent
      ))
    controller.modelRuntime.modelState = .ready
    controller.draft = "summarize the README"

    controller.sendMessage(in: workspace, sessionID: sessionID)

    try await waitUntil { !controller.isGenerating }

    let capturedMessages = await runtime.capturedMessages
    #expect(capturedMessages.count == 2)
    let followUp = try #require(capturedMessages.last?.last(where: { $0.role == .user }))
    #expect(followUp.content.contains("Original user request:"))
    #expect(followUp.content.contains("summarize the README"))
    #expect(followUp.content.contains("Assistant tool call:"))
    #expect(followUp.content.contains("tool=\"read_file\""))
    #expect(followUp.content.contains("Tool observation:"))
    #expect(followUp.content.contains("1: project notes"))
    #expect(
      controller.chatSession.toolCalls.first?.turnID == controller.chatSession.turns.first?.id)
  }

  @Test
  func nativeWebFetchFollowUpIncludesOriginalUserRequestAndToolObservation() async throws {
    let sessionID = UUID()
    let workspace = Workspace(
      name: "Project",
      rootURL: URL(filePath: Workspace.normalizedPath(for: FileManager.default.temporaryDirectory)),
      sessions: [
        ChatSession(
          id: sessionID,
          selectedModelID: "gemma4-e2b",
          interactionMode: .agent
        )
      ]
    )
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "web_fetch",
            arguments: ["url": .string("https://example.com/article")]
          ))
      ],
      [.chunk("The article says fetched fixture text.")],
    ])
    let orchestrator = ToolOrchestrator(
      executorRegistry: .codingAgent,
      webFetcher: ChatControllerFakeFetcher(),
      webAccessSettingsProvider: {
        WebAccessSettings(policy: .allow, provider: .duckDuckGo)
      }
    )
    let controller = ChatSessionController(
      runtime: runtime,
      modelPath: "/tmp/model",
      toolOrchestrator: orchestrator
    )
    controller.loadSession(
      ChatSession(
        id: sessionID,
        selectedModelID: "gemma4-e2b",
        interactionMode: .agent
      ))
    controller.modelRuntime.modelState = .ready
    controller.draft = "read and summarize this article https://example.com/article"

    controller.sendMessage(in: workspace, sessionID: sessionID)

    try await waitUntil { !controller.isGenerating }

    let capturedMessages = await runtime.capturedMessages
    #expect(capturedMessages.count == 2)
    let followUp = try #require(capturedMessages.last?.last(where: { $0.role == .user }))
    #expect(followUp.content.contains("Original user request:"))
    #expect(followUp.content.contains("read and summarize this article"))
    #expect(followUp.content.contains("Assistant tool call:"))
    #expect(followUp.content.contains("tool=\"web_fetch\""))
    #expect(followUp.content.contains("Tool observation:"))
    #expect(followUp.content.contains("Fetched fixture text."))
    #expect(
      controller.chatSession.toolCalls.first?.turnID == controller.chatSession.turns.first?.id)
  }

  @Test
  func sendMessageDisplaysShowFileResultDirectlyWithoutModelFollowUp() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appending(
      path: "local-coder-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    try "project notes".write(
      to: rootURL.appending(path: "README.md"),
      atomically: true,
      encoding: .utf8
    )
    let sessionID = UUID()
    let workspace = Workspace(
      name: "Project",
      rootURL: URL(filePath: Workspace.normalizedPath(for: rootURL)),
      sessions: [
        ChatSession(
          id: sessionID,
          selectedModelID: ManagedModelCatalog.defaultModelID,
          systemPrompt: ChatPromptDefaults.codingSystemPrompt,
          generationSettings: .codingDefault
        )
      ]
    )
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "show_file",
            arguments: ["path": .string("README.md")]
          ))
      ]
    ])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.setInteractionMode(.agent)
    controller.draft = "show the content of README.md"

    controller.sendMessage(in: workspace, sessionID: sessionID)

    try await waitUntil { !controller.isGenerating }

    #expect(controller.errorMessage == nil)
    #expect(controller.chatSession.toolCalls.count == 1)
    #expect(controller.chatSession.testMessages.count == 4)
    #expect(controller.chatSession.testMessages[1].kind == .toolCall)
    #expect(controller.chatSession.testMessages[2].kind == .toolResult)
    #expect(controller.chatSession.testMessages[3].kind == .assistant)
    #expect(controller.chatSession.testMessages[3].content.contains("Here is `README.md`:"))
    #expect(controller.chatSession.testMessages[3].content.contains("1: project notes"))
    #expect(
      controller.chatSession.modelContextSnapshot.entries.map(\.frozenContent.role) == [
        .user, .assistant, .user, .assistant,
      ])
    #expect(
      controller.chatSession.modelContextSnapshot.entries[2].frozenContent.content.contains(
        "Displayed file to user: README.md"))
    #expect(
      !controller.chatSession.modelContextSnapshot.entries[2].frozenContent.content.contains(
        "1: project notes"))
    #expect(
      controller.chatSession.modelContextSnapshot.entries[3].frozenContent.content
        == "Displayed show_file result for README.md directly to the user.")

    let capturedMessages = await runtime.capturedMessages
    #expect(capturedMessages.count == 1)
  }

  @Test
  func sendMessageKeepsToolCallHistoryWhenFollowUpResponseFails() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appending(
      path: "local-coder-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    try "project notes".write(
      to: rootURL.appending(path: "README.md"),
      atomically: true,
      encoding: .utf8
    )
    let sessionID = UUID()
    let workspace = Workspace(
      name: "Project",
      rootURL: URL(filePath: Workspace.normalizedPath(for: rootURL)),
      sessions: [
        ChatSession(
          id: sessionID,
          selectedModelID: ManagedModelCatalog.defaultModelID,
          systemPrompt: ChatPromptDefaults.codingSystemPrompt,
          generationSettings: .codingDefault
        )
      ]
    )
    let runtime = ChatSessionFakeChatModelRuntime(
      eventTurns: [
        [
          .toolCall(
            ChatRuntimeToolCall(
              name: "read_file",
              arguments: ["path": .string("README.md")]
            ))
        ],
        [],
      ],
      failingStreamReplyCalls: [1]
    )
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.setInteractionMode(.agent)
    controller.draft = "Read the README"

    controller.sendMessage(in: workspace, sessionID: sessionID)

    try await waitUntil { !controller.isGenerating }

    #expect(
      controller.errorMessage
        == ChatSessionFakeChatModelRuntimeError.streamFailed.localizedDescription)
    #expect(controller.chatSession.testMessages.count == 3)
    #expect(controller.chatSession.testMessages[1].toolCall?.toolName == .readFile)
    #expect(controller.chatSession.testMessages[1].content.isEmpty)
    #expect(controller.chatSession.testMessages[2].toolResult?.toolName == .readFile)
    #expect(controller.chatSession.testMessages[2].kind == .toolResult)
    #expect(
      !controller.chatSession.testMessages.contains { message in
        message.kind == .assistant && message.content.isEmpty
      })
  }

  @Test
  func refreshContextUsagePublishesEstimateWithoutRuntimeTokenization() async throws {
    let runtime = ControlledContextUsageRuntime()
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.chatSession.testMessages = [TestTranscriptMessage(userContent: "hello")]

    controller.refreshContextUsage()
    controller.refreshContextUsage()
    await Task.yield()

    #expect(controller.contextUsage?.accuracy == .estimate)
    #expect(controller.contextUsage?.isStale == false)
    #expect(await runtime.contextUsageRequestCount == 0)
    #expect(await runtime.completedContextUsageCount == 0)
  }

  @Test
  func refreshContextUsageEstimatesWhileGeneratingWithoutDeferredTokenization() async throws {
    let runtime = ControlledStreamingRuntime(turns: [["done"]], blockedCallIndexes: [0])
    defer { Task { await runtime.releaseStream(callIndex: 0) } }
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.draft = "Wait before answering"

    controller.sendMessage()

    try await waitUntilAsync { await runtime.startedStreamCount == 1 }
    controller.refreshContextUsage()
    await Task.yield()

    #expect(await runtime.contextUsageRequestCount == 0)
    #expect(controller.contextUsage?.accuracy == .estimate)
    #expect(controller.contextUsage?.isStale == false)

    await runtime.releaseStream(callIndex: 0)
    try await waitUntil { !controller.isGenerating }
    try await Task.sleep(for: .milliseconds(50))
    #expect(await runtime.contextUsageRequestCount == 0)
  }

  @Test
  func clearChatHistoryDoesNotPublishStaleContextUsageAfterModelChange() async throws {
    let modelDirectory = try makeModelDirectory(config: #"{"n_ctx":2048}"#)
    let runtime = DelayedClearContextRuntime()
    defer { Task { await runtime.releaseClearContext() } }
    let controller = ChatSessionController(
      runtime: runtime,
      modelPath: modelDirectory.path(percentEncoded: false)
    )
    controller.modelRuntime.modelState = .ready
    controller.contextUsage = ChatContextUsage(usedTokens: 12, tokenLimit: 128)
    controller.chatSession.testMessages = [TestTranscriptMessage(userContent: "old session")]

    controller.clearChatHistory()
    try await waitUntilAsync { await runtime.didStartClearContext }

    controller.prepareForModelRuntimeAction(cancelGeneration: false, invalidateContext: true)
    controller.modelRuntime.loadModel()
    try await waitUntil { controller.contextUsage?.usedTokens != 12 }

    await runtime.releaseClearContext()
    try await waitUntilAsync { await runtime.didFinishClearContext }
    try await waitUntil(timeout: .seconds(2)) { controller.modelRuntime.modelState == .ready }

    #expect(controller.modelRuntime.modelState == .ready)
    #expect(controller.contextUsage?.usedTokens != 12)
  }

  @Test
  func staleAttachmentLoadDoesNotAppendAfterNewerAttachmentRequest() async throws {
    let loader = BlockingFirstAttachmentLoader()
    defer { loader.releaseFirstLoad() }
    let controller = ChatSessionController(
      runtime: ChatSessionFakeChatModelRuntime(),
      modelPath: "/tmp/model",
      chatAttachmentLoader: loader
    )

    controller.addAttachments(from: [URL(filePath: "/tmp/first.swift")])
    try await waitUntil { loader.startedCount == 1 }

    controller.addAttachments(from: [URL(filePath: "/tmp/second.swift")])
    try await waitUntil {
      controller.chatSession.pendingAttachments.map(\.displayName) == ["second.swift"]
    }

    loader.releaseFirstLoad()
    try await waitUntil { loader.completedCount == 2 }
    await Task.yield()

    #expect(controller.chatSession.pendingAttachments.map(\.displayName) == ["second.swift"])
  }

  private func waitUntil(
    timeout: Duration = .seconds(1),
    condition: @escaping @MainActor () -> Bool
  ) async throws {
    let start = ContinuousClock.now
    while !condition() {
      if start.duration(to: .now) > timeout {
        Issue.record("Timed out waiting for condition")
        throw TestWaitTimeoutError()
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private func waitUntilAsync(
    timeout: Duration = .seconds(1),
    condition: @escaping () async -> Bool
  ) async throws {
    let start = ContinuousClock.now
    while !(await condition()) {
      if start.duration(to: .now) > timeout {
        Issue.record("Timed out waiting for async condition")
        throw TestWaitTimeoutError()
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private func makeWorkspace(sessionID: ChatSession.ID) throws -> Workspace {
    let rootURL = FileManager.default.temporaryDirectory.appending(
      path: "local-coder-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    try "project notes".write(
      to: rootURL.appending(path: "README.md"),
      atomically: true,
      encoding: .utf8
    )
    return Workspace(
      name: "Project",
      rootURL: URL(filePath: Workspace.normalizedPath(for: rootURL)),
      sessions: [
        ChatSession(
          id: sessionID,
          selectedModelID: ManagedModelCatalog.defaultModelID,
          systemPrompt: ChatPromptDefaults.codingSystemPrompt,
          generationSettings: .codingDefault
        )
      ]
    )
  }

  private func makeModelDirectory(config: String) throws -> URL {
    let modelDirectory = FileManager.default.temporaryDirectory.appending(
      path: "local-coder-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
    try config.write(
      to: modelDirectory.appending(path: "config.json", directoryHint: .notDirectory),
      atomically: true,
      encoding: .utf8
    )
    return modelDirectory
  }

  private func messageID(from item: ChatTurnItem) -> UUID? {
    switch item {
    case .userMessage(let message):
      message.id
    case .assistantMessage(let message):
      message.id
    case .toolCall, .toolResult:
      nil
    }
  }
}

private struct ChatControllerFakeFetcher: WebFetching {
  func fetch(_ request: WebFetchRequest) async -> WebFetchToolResult {
    WebFetchToolResult(
      url: request.url.absoluteString,
      finalURL: request.url.absoluteString,
      statusCode: 200,
      contentType: "text/plain",
      content: ToolTextOutput(text: "Fetched fixture text."),
      byteCount: 21
    )
  }
}
