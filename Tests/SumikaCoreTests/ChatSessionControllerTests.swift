import Foundation
import Testing

@testable import SumikaCore

@Suite(.serialized)
@MainActor
struct ChatSessionControllerTests {
  @Test
  func releasingControllerReleasesTestModelComposition() async throws {
    weak var modelController: ModelRuntimeController?

    do {
      let controller = ChatSessionController(
        runtime: ChatSessionFakeChatModelRuntime(),
        modelPath: "/tmp/model"
      )
      modelController = controller.modelRuntime
      #expect(modelController != nil)
    }

    try await waitUntil(timeout: .seconds(1)) {
      modelController == nil
    }
  }

  @Test
  func canSendRequiresReadyModelNonEmptyPromptAndIdleGeneration() {
    let controller = ChatSessionController(
      runtime: ChatSessionFakeChatModelRuntime(),
      modelPath: "/tmp/model"
    )

    controller.modelRuntime.modelState = .ready

    #expect(controller.canSend(prompt: "  hello  "))

    #expect(!controller.canSend(prompt: "   "))

    controller.isGenerating = true
    #expect(!controller.canSend(prompt: "hello"))
  }

  @Test
  func canSendIgnoresPendingToolInteractions() {
    let approvalRecord = makeToolCallRecord(status: .awaitingApproval)
    let askUserRecord = makeToolCallRecord(status: .awaitingUserAnswer)
    let controller = ChatSessionController(
      runtime: ChatSessionFakeChatModelRuntime(),
      modelPath: "/tmp/model",
      chatSession: ChatSession(turns: [
        ChatTurn(status: .awaitingApproval, items: [.tool(approvalRecord)]),
        ChatTurn(status: .awaitingUserAnswer, items: [.tool(askUserRecord)]),
      ])
    )
    controller.modelRuntime.modelState = .ready

    #expect(controller.hasPendingApproval)
    #expect(controller.hasPendingUserAnswer)
    #expect(controller.canSend(prompt: "continue with a new instruction"))
  }

  @Test
  func interruptingPendingInteractionAppliesQueuedAgentToolRegistry() async throws {
    let runtime = ChatSessionFakeChatModelRuntime(chunks: ["new answer"])
    let selectedServerID = UUID()
    let approvalRecord = makeToolCallRecord(status: .awaitingApproval)
    let sessionID = UUID()
    let controller = ChatSessionController(
      runtime: runtime,
      modelPath: "/tmp/model",
      chatSession: ChatSession(
        id: sessionID,
        turns: [
          ChatTurn(status: .awaitingApproval, items: [.tool(approvalRecord)])
        ],
        interactionMode: .agent
      )
    )
    let workspace = try makeWorkspace(sessionID: sessionID)
    controller.modelRuntime.modelState = .ready

    controller.reconcileSelectedMCPServerIDs(
      [selectedServerID],
      agentToolExecutorRegistry: .readOnly
    )

    #expect(controller.chatSession.selectedMCPServerIDs.isEmpty)
    #expect(
      controller.sendMessage(
        prompt: "continue with the updated tools",
        in: workspace,
        sessionID: sessionID
      )
    )
    try await waitUntil { !controller.isGenerating }

    let capturedToolContexts = await runtime.capturedToolContexts
    let toolContext = try #require(capturedToolContexts.first ?? nil)
    #expect(toolContext.registry.definition(for: .readFile) != nil)
    #expect(toolContext.registry.definition(for: .editFile) == nil)
    #expect(controller.chatSession.selectedMCPServerIDs == [selectedServerID])
  }

  @Test
  func composerSessionStateIgnoresTranscriptOnlyChanges() {
    let controller = ChatSessionController(
      runtime: ChatSessionFakeChatModelRuntime(),
      modelPath: "/tmp/model",
      chatSession: ChatSession(
        turns: [
          ChatTurn(
            status: .completed,
            items: [.userMessage(UserTurnMessage(content: "transcript-only change"))]
          )
        ],
        interactionMode: .agent
      )
    )
    let originalState = controller.composerSessionState

    controller.clearChatHistory()

    #expect(controller.composerSessionState == originalState)
  }

  @Test
  func composerSessionStateTracksComposerRelevantSessionFields() throws {
    let attachment = makeAttachment(name: "screenshot.png", kind: .image)
    let todoState = TodoState(items: [
      TodoItem(id: "1", content: "Inspect files", status: .completed),
      TodoItem(id: "2", content: "Run tests", status: .pending),
    ])
    let mcpServerID = UUID()
    let controller = ChatSessionController(
      runtime: ChatSessionFakeChatModelRuntime(),
      modelPath: "/tmp/model",
      chatSession: ChatSession(
        pendingAttachments: [attachment],
        interactionMode: .chat,
        selectedMCPServerIDs: [mcpServerID],
        todoState: todoState,
        activeAttachmentContext: ActiveAttachmentContext(
          attachmentIDs: [attachment.id]
        )
      )
    )

    #expect(controller.composerSessionState.pendingAttachments == [attachment])
    #expect(controller.composerSessionState.activeAttachments == [attachment])
    #expect(controller.composerSessionState.interactionMode == .chat)
    #expect(controller.composerSessionState.toolApprovalPolicy == .manual)
    #expect(controller.composerSessionState.selectedMCPServerIDs == [mcpServerID])
    #expect(controller.composerSessionState.todoState == nil)

    controller.setInteractionMode(.agent)
    controller.enableAutomaticToolApproval(
      in: try makeWorkspace(sessionID: controller.sessionID)
    )

    #expect(controller.composerSessionState.interactionMode == .agent)
    #expect(controller.composerSessionState.toolApprovalPolicy == .automatic)
    #expect(controller.composerSessionState.todoState == todoState)
  }

  @Test
  func mcpServerSelectionIsAgentOnlyAndBlockedDuringGeneration() {
    let controller = ChatSessionController(
      runtime: ChatSessionFakeChatModelRuntime(),
      modelPath: "/tmp/model"
    )
    let first = UUID()
    let second = UUID()

    #expect(!controller.canChangeMCPServerSelection)
    controller.setSelectedMCPServerIDs(
      [first],
      agentToolExecutorRegistry: .codingAgent
    )
    #expect(controller.chatSession.selectedMCPServerIDs.isEmpty)

    controller.setInteractionMode(.agent)
    #expect(controller.canChangeMCPServerSelection)
    controller.setSelectedMCPServerIDs(
      [first],
      agentToolExecutorRegistry: .codingAgent
    )
    #expect(controller.chatSession.selectedMCPServerIDs == [first])
    #expect(controller.composerSessionState.selectedMCPServerIDs == [first])

    controller.isGenerating = true
    controller.setSelectedMCPServerIDs(
      [second],
      agentToolExecutorRegistry: .codingAgent
    )
    #expect(controller.chatSession.selectedMCPServerIDs == [first])
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
    let mcpServerID = UUID()
    let session = ChatSession(
      selectedModelID: ManagedModelCatalog.defaultModelID,
      focusedFileState: focusedFileState,
      modeSettings: testModeSettings(
        mode: .agent,
        systemPrompt: "System",
        generationSettings: .agentDefault
      ),
      interactionMode: .agent,
      toolApprovalPolicy: .automatic,
      selectedMCPServerIDs: [mcpServerID]
    )
    let controller = ChatSessionController(
      runtime: ChatSessionFakeChatModelRuntime(),
      modelPath: "/tmp/model"
    )

    controller.loadSession(session)
    let snapshot = controller.sessionSnapshot(updating: session)

    #expect(controller.chatSession.focusedFileState == focusedFileState)
    #expect(controller.chatSession.interactionMode == .agent)
    #expect(controller.chatSession.toolApprovalPolicy == .automatic)
    #expect(snapshot.focusedFileState == focusedFileState)
    #expect(snapshot.interactionMode == .agent)
    #expect(snapshot.toolApprovalPolicy == .automatic)
    #expect(snapshot.selectedMCPServerIDs == [mcpServerID])
  }

  @Test
  func sessionSnapshotCarriesLiveTodoState() {
    let controller = ChatSessionController(
      runtime: ChatSessionFakeChatModelRuntime(),
      modelPath: "/tmp/model"
    )
    let staleTodoState = TodoState(items: [
      TodoItem(id: "1", content: "Outdated plan", status: .pending)
    ])
    let liveTodoState = TodoState(items: [
      TodoItem(id: "1", content: "Inspect files", status: .completed),
      TodoItem(id: "2", content: "Run tests", status: .inProgress),
    ])
    let persisted = ChatSession(interactionMode: .agent, todoState: staleTodoState)

    controller.loadSession(
      ChatSession(
        id: persisted.id,
        interactionMode: .agent,
        todoState: liveTodoState
      ))

    #expect(controller.sessionSnapshot(updating: persisted).todoState == liveTodoState)

    controller.loadSession(
      ChatSession(
        id: persisted.id,
        interactionMode: .agent
      ))

    #expect(controller.sessionSnapshot(updating: persisted).todoState == nil)
  }

  @Test
  func loadSessionClearsRuntimeContextWhenModelIsReused() async throws {
    let runtime = CountingClearContextRuntime()
    let session = ChatSession(
      selectedModelID: ManagedModelCatalog.defaultModelID,
      modeSettings: testModeSettings(
        mode: .agent,
        systemPrompt: "System",
        generationSettings: .agentDefault
      ),
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
      modeSettings: testModeSettings(
        mode: .agent,
        systemPrompt: "System",
        generationSettings: .agentDefault
      ),
      interactionMode: .agent
    )
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .loading

    controller.loadSession(session)
    await Task.yield()

    #expect(await runtime.clearContextCount == 0)
  }

  @Test
  func selectModelPreservesTranscriptAndClearsRuntimeContext() async throws {
    let runtime = CountingClearContextRuntime()
    let originalTurn = ChatTurn(
      status: .completed,
      items: [.userMessage(UserTurnMessage(content: "old session"))]
    )
    let controller = ChatSessionController(
      runtime: runtime,
      modelPath: "/tmp/model",
      chatSession: ChatSession(turns: [originalTurn])
    )
    let targetModel = try #require(ManagedModelCatalog.model(id: "gemma4-12b-qat-4bit"))
    controller.modelRuntime.modelState = .ready
    controller.modelRuntime.selectedModelID = "gemma4-26b-qat-4bit"
    controller.contextUsage = ChatContextUsage(usedTokens: 12, tokenLimit: 128)

    controller.modelRuntime.selectModel(targetModel)

    try await waitUntilAsync { await runtime.clearContextCount == 1 }
    let snapshot = controller.sessionSnapshot(updating: controller.chatSession)
    #expect(controller.chatSession.turns == [originalTurn])
    #expect(snapshot.turns == [originalTurn])
    #expect(snapshot.selectedModelID == targetModel.id)
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
  func automaticApprovalIsAgentOnlyRetainedAcrossModeChangesAndDisablesImmediately() throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let controller = ChatSessionController(
      runtime: ChatSessionFakeChatModelRuntime(),
      modelPath: "/tmp/model"
    )

    #expect(!controller.canEnableAutomaticToolApproval)
    controller.setInteractionMode(.agent)
    #expect(controller.canEnableAutomaticToolApproval)

    controller.enableAutomaticToolApproval(in: workspace)
    #expect(controller.chatSession.toolApprovalPolicy == .automatic)
    #expect(!controller.canEnableAutomaticToolApproval)

    controller.setInteractionMode(.chat)
    #expect(controller.chatSession.toolApprovalPolicy == .automatic)
    #expect(!controller.canEnableAutomaticToolApproval)

    controller.setInteractionMode(.agent)
    #expect(controller.chatSession.toolApprovalPolicy == .automatic)

    controller.disableAutomaticToolApproval()
    #expect(controller.chatSession.toolApprovalPolicy == .manual)
    #expect(controller.canEnableAutomaticToolApproval)

    controller.loadSession(
      ChatSession(
        id: controller.sessionID,
        turns: [
          ChatTurn(
            status: .awaitingApproval,
            items: [.tool(makeToolCallRecord(status: .awaitingApproval))]
          )
        ],
        interactionMode: .agent
      ))
    #expect(controller.canEnableAutomaticToolApproval)

    controller.loadSession(
      ChatSession(
        id: controller.sessionID,
        turns: [
          ChatTurn(
            status: .awaitingUserAnswer,
            items: [.tool(makeToolCallRecord(status: .awaitingUserAnswer))]
          )
        ],
        interactionMode: .agent
      ))
    #expect(!controller.canEnableAutomaticToolApproval)
  }

  @Test
  func loadSessionForExperimentalGemma4PreservesToolMode() {
    let session = ChatSession(
      selectedModelID: "gemma4-12b-qat-4bit",
      interactionMode: .agent
    )
    let controller = ChatSessionController(
      runtime: ChatSessionFakeChatModelRuntime(),
      modelPath: "/tmp/model"
    )

    controller.loadSession(session)

    #expect(controller.modelRuntime.selectedModelID == "gemma4-12b-qat-4bit")
    #expect(controller.chatSession.interactionMode == .agent)
    #expect(controller.errorMessage == nil)
  }

  @Test
  func setInteractionModeAllowsExperimentalGemma4ToolModes() {
    let session = ChatSession(selectedModelID: "gemma4-12b-qat-4bit")
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
  func runtimeRequestsUseActiveModePromptAndGenerationSettings() async throws {
    let chatSettings = ChatGenerationSettings(
      temperature: 1.2,
      topP: 0.95,
      topK: 30,
      maxTokens: 768
    )
    let agentSettings = ChatGenerationSettings(
      temperature: 0.1,
      topP: 0.7,
      topK: 10,
      maxTokens: 256
    )
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [.chunk("chat response")],
      [.chunk("agent response")],
    ])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.updateModeSettings(
      ChatModeSettingsSet(
        chat: ChatModeSettings(
          systemPrompt: "Chat mode prompt",
          generationSettings: chatSettings
        ),
        agent: ChatModeSettings(
          systemPrompt: "Agent mode prompt",
          generationSettings: agentSettings
        )
      )
    )

    #expect(controller.sendMessage(prompt: "hello"))
    try await waitUntilAsync { await runtime.capturedGenerationSettings.count == 1 }

    controller.setInteractionMode(.agent)
    #expect(controller.sendMessage(prompt: "inspect"))
    try await waitUntilAsync { await runtime.capturedGenerationSettings.count == 2 }

    let prompts = await runtime.capturedSystemPrompts
    let settings = await runtime.capturedGenerationSettings
    #expect(prompts[0].contains("Chat mode prompt"))
    #expect(!prompts[0].contains("Agent mode prompt"))
    #expect(settings[0] == chatSettings)
    #expect(prompts[1].contains("Agent mode prompt"))
    #expect(!prompts[1].contains("Chat mode prompt"))
    #expect(settings[1] == agentSettings)
  }

  @Test
  func setReasoningEnabledMutatesOnlyActiveModeSettings() {
    let controller = ChatSessionController(
      runtime: ChatSessionFakeChatModelRuntime(),
      modelPath: "/tmp/model",
      chatSession: ChatSession(
        modeSettings: ChatModeSettingsSet(
          chat: ChatModeSettings(
            systemPrompt: "Chat mode prompt",
            generationSettings: ChatGenerationSettings(
              temperature: 1,
              topP: 1,
              topK: 0,
              maxTokens: 256,
              reasoningEnabled: true
            )
          ),
          agent: ChatModeSettings(
            systemPrompt: "Agent mode prompt",
            generationSettings: ChatGenerationSettings(
              temperature: 0,
              topP: 1,
              topK: 0,
              maxTokens: 256,
              reasoningEnabled: true
            )
          )
        ),
        interactionMode: .chat
      )
    )

    controller.setReasoningEnabled(false)

    #expect(!controller.chatSession.modeSettings.chat.generationSettings.reasoningEnabled)
    #expect(controller.chatSession.modeSettings.agent.generationSettings.reasoningEnabled)
    #expect(!controller.composerSessionState.reasoningEnabled)
  }

  @Test
  func modelContextDebugDocumentUsesWorkspaceToolAvailability() throws {
    let session = ChatSession(
      selectedModelID: "gemma4-12b-qat-4bit",
      modeSettings: testModeSettings(
        mode: .agent,
        systemPrompt: "Base system prompt",
        generationSettings: .agentDefault
      ),
      interactionMode: .agent
    )
    let controller = ChatSessionController(
      runtime: ChatSessionFakeChatModelRuntime(),
      modelPath: "/tmp/model"
    )
    controller.loadSession(session)
    let workspace = Workspace(
      name: "Project",
      rootURL: URL(filePath: "/tmp/project"),
      sessions: [controller.chatSession]
    )

    let unavailableDocument = try controller.modelContextDebugDocument()
    let availableDocument = try controller.modelContextDebugDocument(
      workspace: workspace,
      sessionID: controller.chatSession.id
    )

    #expect(!unavailableDocument.systemPrompt.content.contains("Use available workspace tools"))
    #expect(availableDocument.systemPrompt.content.contains("Use available workspace tools"))
  }

  @Test
  func modelContextDebugStateTracksRevisionAndRuntimeCacheSnapshot() async throws {
    let generationID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000123"))
    let snapshot = RuntimeCacheDebugSnapshot(
      generationID: generationID,
      recordedAt: Date(timeIntervalSince1970: 1_234),
      cacheMode: "append_delta",
      cacheReason: "append_only_delta",
      reuseStrategy: "append_delta",
      appendDeltaStartIndex: 1,
      contextSignature: "current",
      previousContextSignature: "previous",
      appendOnly: true,
      reusedMessageCount: 2,
      appendedMessageCount: 1
    )
    let runtime = ChatSessionFakeChatModelRuntime(chunks: ["done"], debugSnapshot: snapshot)
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    let initialRevision = controller.modelContextDebugState.documentRevision

    controller.loadSession(ChatSession(selectedModelID: ManagedModelCatalog.defaultModelID))

    #expect(controller.modelContextDebugState.documentRevision > initialRevision)

    controller.modelRuntime.modelState = .ready
    controller.sendMessage(prompt: "hello")

    try await waitUntil { controller.modelContextDebugState.runtimeCacheDebugSnapshot == snapshot }

    let revisionAfterSend = controller.modelContextDebugState.documentRevision
    controller.clearChatHistory()

    #expect(controller.modelContextDebugState.runtimeCacheDebugSnapshot == nil)
    #expect(controller.modelContextDebugState.documentRevision > revisionAfterSend)
  }

  @Test
  func sendMessageAllowsExperimentalGemma4PersistedToolMode() async throws {
    let runtime = ChatSessionFakeChatModelRuntime(chunks: ["native mode response"])
    let controller = ChatSessionController(
      runtime: runtime,
      modelPath: "/tmp/model",
      chatSession: ChatSession(
        selectedModelID: "gemma4-12b-qat-4bit",
        interactionMode: .agent
      )
    )
    controller.modelRuntime.modelState = .ready
    controller.sendMessage(prompt: "inspect files")
    try await waitUntil { !controller.isGenerating }

    #expect(!controller.chatSession.turns.isEmpty)
    #expect(controller.errorMessage == nil)
  }

  @Test
  func sendMessageNamesDefaultSessionFromFirstPrompt() async throws {
    let runtime = ChatSessionFakeChatModelRuntime(chunks: ["done"])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    let session = ChatSession(selectedModelID: ManagedModelCatalog.defaultModelID)
    controller.loadSession(session)
    controller.modelRuntime.modelState = .ready
    controller.sendMessage(prompt: "  build   a snake game\nin python  ")
    try await waitUntil { !controller.isGenerating }

    #expect(controller.chatSession.title == "build a snake game in python")
    #expect(controller.sessionSnapshot(updating: session).title == "build a snake game in python")
  }

  @Test
  func renameSessionNormalizesTitleAndNotifiesChange() {
    let controller = ChatSessionController(
      runtime: ChatSessionFakeChatModelRuntime(),
      modelPath: "/tmp/model"
    )
    var changeCount = 0
    controller.setSessionChangeHandler {
      changeCount += 1
    }

    #expect(controller.renameSession(to: "  Manual title  "))
    #expect(controller.chatSession.title == "Manual title")
    #expect(changeCount == 1)
    #expect(!controller.renameSession(to: "   "))
    #expect(controller.chatSession.title == "Manual title")
    #expect(changeCount == 1)
  }

  @Test
  func sendMessageDoesNotRenameManualTitle() async throws {
    let runtime = ChatSessionFakeChatModelRuntime(chunks: ["done"])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.loadSession(
      ChatSession(
        title: "Manual title",
        selectedModelID: ManagedModelCatalog.defaultModelID
      )
    )
    controller.modelRuntime.modelState = .ready
    controller.sendMessage(prompt: "first prompt")
    try await waitUntil { !controller.isGenerating }

    #expect(controller.chatSession.title == "Manual title")
  }

  @Test
  func sendMessageDoesNotRenameExistingConversation() async throws {
    let runtime = ChatSessionFakeChatModelRuntime(chunks: ["done"])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    let existingTurn = ChatTurn(
      status: .completed,
      items: [.userMessage(UserTurnMessage(content: "original prompt"))]
    )
    controller.loadSession(
      ChatSession(
        selectedModelID: ManagedModelCatalog.defaultModelID,
        turns: [existingTurn]
      )
    )
    controller.modelRuntime.modelState = .ready
    controller.sendMessage(prompt: "second prompt")
    try await waitUntil { !controller.isGenerating }

    #expect(controller.chatSession.title == ChatSession.defaultTitle)
  }

  @Test
  func sendMessageDoesNotFreezeBaseSystemPromptIntoUserEntriesAcrossTurns() async throws {
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [.chunk("first answer")],
      [.chunk("second answer")],
    ])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.loadSession(
      ChatSession(
        selectedModelID: "gemma4-12b-qat-4bit",
        modeSettings: testModeSettings(
          systemPrompt: "Base system prompt",
          generationSettings: .chatDefault
        )
      ))
    controller.modelRuntime.modelState = .ready

    controller.sendMessage(prompt: "first")
    try await waitUntil { !controller.isGenerating }

    controller.sendMessage(prompt: "second")
    try await waitUntil { !controller.isGenerating }

    let projection = ChatModelContextBuilder().transcript(from: controller.chatSession)
    let userEntries = projection.entries.filter {
      $0.frozenContent.role == .user
    }
    #expect(userEntries.count == 2)
    #expect(!userEntries.contains { $0.frozenContent.content.contains("Base system prompt") })
    #expect(!userEntries.contains { $0.frozenContent.content.contains("System instructions:") })

    let capturedSystemPrompts = await runtime.capturedSystemPrompts
    #expect(capturedSystemPrompts == ["Base system prompt", "Base system prompt"])
    let secondRuntimeMessages = try #require(await runtime.capturedMessages.last)
    let userRuntimeMessages = secondRuntimeMessages.filter { $0.role == .user }
    #expect(userRuntimeMessages.count == 2)
    #expect(!userRuntimeMessages.contains { $0.content.contains("Base system prompt") })
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

    controller.sendMessage(prompt: "hello")
    await Task.yield()

    #expect(await runtime.streamReplyCount == 0)

    await runtime.releaseClearContext()

    try await waitUntilAsync { await runtime.streamReplyCount == 1 }
    try await waitUntil { !controller.isGenerating }
  }

  @Test
  func sendMessageStreamsAssistantReplyAndClearsAttachments() async throws {
    let attachment = ChatAttachment(
      url: URL(filePath: "/tmp/source.swift"),
      displayName: "source.swift",
      kind: .text,
      content: "let value = 1"
    )
    let runtime = ChatSessionFakeChatModelRuntime(chunks: ["hello", " world"])
    let controller = ChatSessionController(
      runtime: runtime,
      modelPath: "/tmp/model",
      chatSession: ChatSession(pendingAttachments: [attachment])
    )
    controller.modelRuntime.modelState = .ready

    controller.sendMessage(prompt: "Explain this")

    try await waitUntil { !controller.isGenerating }

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
    let projection = ChatModelContextBuilder().transcript(from: controller.chatSession)
    #expect(projection.entries.map(\.frozenContent.role) == [.user, .assistant])
    #expect(
      projection.entries[0].frozenContent.content.contains(
        "Attached file: source.swift"))
    #expect(
      projection.entries[0].frozenContent.content.contains(
        "Attached content excerpt:"))
    #expect(
      projection.entries[0].frozenContent.content.contains(
        "Attached context:") == false)
    #expect(
      projection.entries[0].frozenContent.content.contains(
        "Explain this"))
    if case .userPrompt(let context) = projection.entries[0].body {
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
    #expect(projection.entries[1].frozenContent.content == "hello world")
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
    let controller = ChatSessionController(
      runtime: runtime,
      modelPath: "/tmp/model",
      chatSession: ChatSession(
        selectedModelID: "gemma4-12b-qat-4bit",
        pendingAttachments: [attachment]
      )
    )
    controller.modelRuntime.modelState = .ready

    controller.sendMessage(prompt: "What is in this screenshot?")

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
    controller.sendMessage(prompt: "Cancel this")

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
    let persistedItems = controller.chatSession.turns[0].items
    #expect(persistedItems.count == 2)
    #expect(persistedItems[0].messageID == controller.chatSession.testMessages[0].id)
    #expect(persistedItems[1].kindForTesting == .assistant)
    #expect(persistedItems[1].contentForTesting.isEmpty)
    #expect(persistedItems[1].deliveryStatusForTesting == .cancelled)
    #expect(controller.errorMessage == nil)
  }

  @Test
  func switchingSessionCancelsOldTurnBeforeApplyingNewModelAndSession() async throws {
    let runtime = NonCooperativeStreamingRuntime(chunks: ["late reply"])
    defer { Task { await runtime.releaseChunks() } }
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    let targetModel = try #require(ManagedModelCatalog.model(id: "gemma4-26b-qat-4bit"))
    let targetSession = ChatSession(selectedModelID: targetModel.id)
    controller.modelRuntime.modelState = .ready
    controller.sendMessage(prompt: "Do not leak this reply")

    try await waitUntilAsync { await runtime.didStartStreaming }

    ConversationSessionCoordinator(
      modelController: controller.modelRuntime,
      chatController: controller
    ).switchSession(to: targetSession)

    #expect(!controller.isGenerating)
    #expect(controller.modelRuntime.selectedModelID == targetModel.id)
    #expect(controller.modelRuntime.modelState == .notLoaded)
    #expect(controller.chatSession.id == targetSession.id)
    #expect(controller.chatSession.turns.isEmpty)

    await runtime.releaseChunks()
    try await waitUntilAsync { await runtime.didFinishStreaming }

    #expect(controller.chatSession.id == targetSession.id)
    #expect(controller.chatSession.turns.isEmpty)
  }

  @Test
  func failedStreamWithPartialOutputDoesNotLeaveAssistantMessageStreaming() async throws {
    let runtime = PartialFailingStreamingRuntime(chunks: ["partial answer"])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.sendMessage(prompt: "fail after partial output")

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
    controller.sendMessage(prompt: "stream ends without completion")

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
    controller.sendMessage(
      prompt: "read README.md before answering", in: workspace, sessionID: sessionID)
    try await waitUntilAsync { await runtime.startedStreamCount == 2 }
    try await waitUntil { controller.chatSession.testMessages.contains { $0.kind == .toolResult } }

    controller.cancelGeneration()
    await runtime.releaseStream(callIndex: 1)
    try await waitUntil { !controller.isGenerating }

    #expect(controller.chatSession.toolCalls.count == 1)
    #expect(controller.chatSession.toolCalls[0].status == .completed)
    let toolMessage = try #require(
      controller.chatSession.testMessages.first { $0.kind == .toolResult })
    #expect(toolMessage.toolCall?.toolName == .readFile)
    #expect(toolMessage.toolResult?.toolName == .readFile)
    #expect(controller.chatSession.turns.count == 1)
    #expect(controller.chatSession.turns[0].status == .cancelled)
    #expect(controller.chatSession.turns[0].modelContextPolicy == .excluded)

    controller.sendMessage(prompt: "are you there", in: workspace, sessionID: sessionID)
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
    controller.sendMessage(prompt: "first")
    try await waitUntilAsync { await runtime.startedStreamCount == 1 }
    controller.cancelGeneration()

    controller.sendMessage(prompt: "second")
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
    controller.sendMessage(prompt: "write a short poem", in: workspace, sessionID: sessionID)

    try await waitUntil { !controller.isGenerating }

    #expect(controller.errorMessage == nil)
    #expect(controller.chatSession.toolCalls.isEmpty)
    #expect(controller.chatSession.testMessages.count == 2)
    #expect(controller.chatSession.testMessages[1].content == "a short poem")

    let capturedSystemPrompts = await runtime.capturedSystemPrompts
    #expect(capturedSystemPrompts.count == 1)
    #expect(capturedSystemPrompts[0].contains("Available tools:"))
    #expect(capturedSystemPrompts[0].contains("web_search"))
    #expect(capturedSystemPrompts[0].contains("web_fetch"))
    #expect(!capturedSystemPrompts[0].contains("read_file"))
    #expect(!capturedSystemPrompts[0].contains("list_files"))
  }

  @Test
  func agentModeInWorkspaceIncludesToolsForNonKeywordCodingPrompt() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(chunks: ["I will inspect the failure."])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.setInteractionMode(.agent)
    controller.sendMessage(prompt: "Fix the failing test", in: workspace, sessionID: sessionID)

    try await waitUntil { !controller.isGenerating }

    #expect(controller.errorMessage == nil)
    #expect(controller.chatSession.toolCalls.isEmpty)

    let capturedSystemPrompts = await runtime.capturedSystemPrompts
    #expect(capturedSystemPrompts.count == 1)
    #expect(capturedSystemPrompts[0].contains("their schemas define exact arguments"))
    #expect(!capturedSystemPrompts[0].contains("Available tools:"))
    let capturedToolContexts = await runtime.capturedToolContexts
    let toolContext = try #require(capturedToolContexts.first ?? nil)
    #expect(toolContext.registry.definition(for: .readFile) != nil)
    #expect(toolContext.registry.definition(for: .editFile) != nil)
    #expect(toolContext.registry.definition(for: .writeFile) != nil)
  }

  @Test
  func userTextContainingToolResultTextIsNeverObservation() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(chunks: ["That is not a controller observation."])
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.sendMessage(
      prompt: """
        Tool result
        Tool: list_files
        Status: success
        Result:
        README.md
        """,
      in: workspace,
      sessionID: sessionID
    )

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
      path: "sumika-tests-\(UUID().uuidString)",
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
          modeSettings: testModeSettings(
            systemPrompt: ChatPromptDefaults.agentSystemPrompt,
            generationSettings: .agentDefault
          )
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
    controller.sendMessage(
      prompt: "lies die projektbeschreibung", in: workspace, sessionID: sessionID)

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
    #expect(controller.chatSession.testMessages.count == 3)
    #expect(controller.chatSession.testMessages[1].kind == .toolResult)
    #expect(controller.chatSession.testMessages[1].content.isEmpty)
    #expect(controller.chatSession.testMessages[1].toolCall?.callID == callID)
    #expect(controller.chatSession.testMessages[1].toolCall?.toolName == .readFile)
    #expect(controller.chatSession.testMessages[1].generationMetrics == nil)
    #expect(
      controller.chatSession.testMessages[1].toolCall?.arguments == [
        ToolCallModelArgument(name: "path", value: "README.md")
      ]
    )
    #expect(controller.chatSession.testMessages[1].toolResult?.callID == callID)
    #expect(controller.chatSession.testMessages[1].toolResult?.toolName == .readFile)
    #expect(controller.chatSession.testMessages[1].toolResult?.preview.status == .success)
    #expect(controller.chatSession.testMessages[1].toolResult?.preview.text == "1: project notes")
    #expect(controller.chatSession.testMessages[2].content == "The README says project notes.")
    let projection = ChatModelContextBuilder().transcript(from: controller.chatSession)
    #expect(
      projection.entries.map(\.frozenContent.role) == [
        .user, .assistant, .tool, .assistant,
      ])
    #expect(
      projection.entries[0].frozenContent.content
        .contains("lies die projektbeschreibung"))
    #expect(projection.entries[1].frozenContent.content.isEmpty)
    #expect(
      projection.entries[2].frozenContent.content.contains(
        "1: project notes"))
    #expect(
      projection.entries[3].frozenContent.content
        == "The README says project notes.")

    let capturedMessages = await runtime.capturedMessages
    #expect(capturedMessages.count == 2)
    #expect(
      capturedMessages[1].last(where: { $0.role == .tool })?.content.contains(
        "1: project notes"
      ) == true)
    #expect(
      capturedMessages[1].contains(where: { message in
        message.role == .tool && message.content.contains("1: project notes")
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
    #expect(capturedSystemPrompts[0] == capturedSystemPrompts[1])
    #expect(!capturedSystemPrompts[1].contains("You received a tool result."))
    #expect(!capturedSystemPrompts[1].contains("Available tools:"))
    #expect(!capturedSystemPrompts[1].contains("Tool calling:"))
    let capturedToolContexts = await runtime.capturedToolContexts
    let followUpToolContext = try #require(capturedToolContexts.last ?? nil)
    #expect(followUpToolContext.registry.definition(for: .readFile) != nil)
    #expect(followUpToolContext.registry.definition(for: .editFile) != nil)
  }

  @Test
  func nativeReadFileFollowUpUsesToolRoleForObservation() async throws {
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
        selectedModelID: "gemma4-12b-qat-4bit",
        interactionMode: .agent
      ))
    controller.modelRuntime.modelState = .ready
    controller.sendMessage(prompt: "summarize the README", in: workspace, sessionID: sessionID)

    try await waitUntil { !controller.isGenerating }

    let capturedMessages = await runtime.capturedMessages
    #expect(capturedMessages.count == 2)
    let followUp = try #require(capturedMessages.last?.last(where: { $0.role == .tool }))
    #expect(!followUp.content.contains("Original user request:"))
    #expect(!followUp.content.contains("summarize the README"))
    #expect(!followUp.content.contains("Assistant tool call:"))
    #expect(followUp.content.contains("TOOL_RESULT_JSON:"))
    #expect(followUp.content.contains("\"tool\":\"read_file\""))
    #expect(followUp.content.contains("CONTENT:"))
    #expect(followUp.content.contains("1: project notes"))
    let toolCallID = try #require(controller.chatSession.toolCalls.first?.id)
    #expect(
      controller.chatSession.turnID(containingToolCall: toolCallID)
        == controller.chatSession.turns.first?.id)
  }

  @Test
  func nativeWebFetchFollowUpUsesToolRoleForObservation() async throws {
    let sessionID = UUID()
    let workspace = Workspace(
      name: "Project",
      rootURL: URL(filePath: Workspace.normalizedPath(for: FileManager.default.temporaryDirectory)),
      sessions: [
        ChatSession(
          id: sessionID,
          selectedModelID: "gemma4-12b-qat-4bit",
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
        selectedModelID: "gemma4-12b-qat-4bit",
        interactionMode: .agent
      ))
    controller.modelRuntime.modelState = .ready
    controller.sendMessage(
      prompt: "read and summarize this article https://example.com/article", in: workspace,
      sessionID: sessionID)

    try await waitUntil { !controller.isGenerating }

    let capturedMessages = await runtime.capturedMessages
    #expect(capturedMessages.count == 2)
    let followUp = try #require(capturedMessages.last?.last(where: { $0.role == .tool }))
    #expect(!followUp.content.contains("Original user request:"))
    #expect(!followUp.content.contains("read and summarize this article"))
    #expect(!followUp.content.contains("Assistant tool call:"))
    #expect(followUp.content.contains("TOOL_RESULT_JSON:"))
    #expect(followUp.content.contains("\"tool\":\"web_fetch\""))
    #expect(followUp.content.contains("CONTENT:"))
    #expect(followUp.content.contains("Fetched fixture text."))
    let toolCallID = try #require(controller.chatSession.toolCalls.first?.id)
    #expect(
      controller.chatSession.turnID(containingToolCall: toolCallID)
        == controller.chatSession.turns.first?.id)
  }

  @Test
  func chatModeNativeWebSearchRunsWithWebOnlyTools() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "web_search",
            arguments: ["query": .string("Swift concurrency")]
          ))
      ],
      [.chunk("The current docs say Swift has structured concurrency.")],
    ])
    let orchestrator = ToolOrchestrator(
      executorRegistry: .codingAgent,
      webSearcher: ChatControllerFakeSearcher(),
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
        selectedModelID: "gemma4-12b-qat-4bit",
        interactionMode: .chat
      ))
    controller.modelRuntime.modelState = .ready
    controller.sendMessage(
      prompt: "what is current in Swift concurrency?", in: workspace, sessionID: sessionID)

    try await waitUntil { !controller.isGenerating }

    let record = try #require(controller.chatSession.toolCalls.first)
    #expect(record.request.toolName == .webSearch)
    #expect(record.status == .completed)
    let capturedMessages = await runtime.capturedMessages
    #expect(capturedMessages.count == 2)
    let followUp = try #require(capturedMessages.last?.last(where: { $0.role == .tool }))
    #expect(followUp.content.contains("TOOL_RESULT_JSON:"))
    #expect(followUp.content.contains("Swift docs fixture."))
  }

  @Test
  func chatWebBudgetFinalizationPassesNoToolContext() async throws {
    let budget = ChatToolLoopLimits.defaultMaxToolLoopIterations
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let toolTurns: [[ChatModelStreamEvent]] = (0..<budget).map { index in
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "web_search",
            arguments: ["query": .string("Swift concurrency \(index)")]
          ))
      ]
    }
    let runtime = ChatSessionFakeChatModelRuntime(
      eventTurns: toolTurns + [[.chunk("Final answer from the collected web results.")]]
    )
    let controller = ChatSessionController(
      runtime: runtime,
      modelPath: "/tmp/model",
      toolOrchestrator: ToolOrchestrator(
        executorRegistry: .codingAgent,
        webSearcher: ChatControllerFakeSearcher(),
        webAccessSettingsProvider: {
          WebAccessSettings(policy: .allow, provider: .duckDuckGo)
        }
      )
    )
    controller.loadSession(
      ChatSession(
        id: sessionID,
        selectedModelID: "gemma4-12b-qat-4bit",
        interactionMode: .chat
      ))
    controller.modelRuntime.modelState = .ready
    controller.sendMessage(
      prompt: "research Swift concurrency", in: workspace, sessionID: sessionID)

    try await waitUntil { !controller.isGenerating }

    #expect(controller.chatSession.turns.first?.status == .completed)
    #expect(
      controller.chatSession.testMessages.last?.content
        == "Final answer from the collected web results.")
    let capturedToolContexts = await runtime.capturedToolContexts
    #expect(capturedToolContexts.count == budget + 1)
    let firstToolContext = try #require(capturedToolContexts.first ?? nil)
    #expect(firstToolContext.registry.tools.map(\.name) == [.webSearch, .webFetch])
    #expect(firstToolContext.registry.definition(for: .finishTask) == nil)
    #expect(capturedToolContexts[budget] == nil)
    let capturedPromptPlans = await runtime.capturedPromptPlans
    #expect(capturedPromptPlans[budget].toolContext == nil)
  }

  @Test
  func chatModeNativeWebFetchFollowUpIncludesToolObservation() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
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
        selectedModelID: "gemma4-12b-qat-4bit",
        interactionMode: .chat
      ))
    controller.modelRuntime.modelState = .ready
    controller.sendMessage(
      prompt: "read and summarize this article https://example.com/article",
      in: workspace,
      sessionID: sessionID
    )

    try await waitUntil { !controller.isGenerating }

    let record = try #require(controller.chatSession.toolCalls.first)
    #expect(record.request.toolName == .webFetch)
    #expect(record.status == .completed)
    let capturedMessages = await runtime.capturedMessages
    #expect(capturedMessages.count == 2)
    let followUp = try #require(capturedMessages.last?.last(where: { $0.role == .tool }))
    #expect(followUp.content.contains("\"tool\":\"web_fetch\""))
    #expect(followUp.content.contains("Fetched fixture text."))
  }

  @Test
  func chatModeDoesNotExposeWorkspaceTools() async throws {
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
      [.chunk("I cannot read local files in Chat mode.")],
    ])
    let controller = ChatSessionController(
      runtime: runtime,
      modelPath: "/tmp/model",
      toolOrchestrator: ToolOrchestrator(
        executorRegistry: .codingAgent,
        webAccessSettingsProvider: {
          WebAccessSettings(policy: .allow, provider: .duckDuckGo)
        }
      )
    )
    controller.loadSession(
      ChatSession(
        id: sessionID,
        selectedModelID: "gemma4-12b-qat-4bit",
        interactionMode: .chat
      ))
    controller.modelRuntime.modelState = .ready
    controller.sendMessage(prompt: "read README.md", in: workspace, sessionID: sessionID)

    try await waitUntil { !controller.isGenerating }

    let record = try #require(controller.chatSession.toolCalls.first)
    #expect(record.request.toolName == .readFile)
    #expect(record.status == .failed)
    #expect(
      record.resultPreview?.text.contains(
        "Tool is not available in the active registry: read_file."
      ) == true)
  }

  @Test
  func chatModeWebFetchRequiresApprovalWhenPolicyAsksEachTime() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "web_fetch",
            arguments: ["url": .string("https://example.com/article")]
          ))
      ],
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "read_file",
            arguments: ["path": .string("README.md")]
          ))
      ],
      [.chunk("Approved fetch completed.")],
    ])
    let controller = ChatSessionController(
      runtime: runtime,
      modelPath: "/tmp/model",
      toolOrchestrator: ToolOrchestrator(
        executorRegistry: .codingAgent,
        webFetcher: ChatControllerFakeFetcher(),
        webAccessSettingsProvider: {
          WebAccessSettings(policy: .askEachTime, provider: .duckDuckGo)
        }
      )
    )
    controller.loadSession(
      ChatSession(
        id: sessionID,
        selectedModelID: "gemma4-12b-qat-4bit",
        interactionMode: .chat
      ))
    controller.modelRuntime.modelState = .ready
    controller.sendMessage(
      prompt: "fetch https://example.com/article", in: workspace, sessionID: sessionID)

    try await waitUntil { controller.chatSession.turns.first?.status == .awaitingApproval }
    let pending = try #require(controller.chatSession.toolCalls.first)
    #expect(pending.status == .awaitingApproval)
    #expect(pending.approvalPreview?.text.contains("Web fetch requires approval") == true)

    controller.setInteractionMode(.agent)
    #expect(controller.chatSession.interactionMode == .chat)

    controller.approveToolCall(id: pending.id, in: workspace)
    try await waitUntil { !controller.isGenerating }

    #expect(controller.chatSession.toolCalls.count == 2)
    #expect(controller.chatSession.toolCalls.first?.status == .completed)
    let blockedRead = try #require(controller.chatSession.toolCalls.last)
    #expect(blockedRead.request.toolName == .readFile)
    #expect(blockedRead.status == .failed)
    #expect(
      blockedRead.resultPreview?.text.contains(
        "Tool is not available in the active registry: read_file."
      ) == true)
    #expect(controller.chatSession.testMessages.last?.content == "Approved fetch completed.")
  }

  @Test
  func chatModeWebAccessOffDeniesWebTools() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [
        .toolCall(
          ChatRuntimeToolCall(
            name: "web_search",
            arguments: ["query": .string("Swift concurrency")]
          ))
      ],
      [.chunk("I cannot search because web access is disabled.")],
    ])
    let controller = ChatSessionController(
      runtime: runtime,
      modelPath: "/tmp/model",
      toolOrchestrator: ToolOrchestrator(
        executorRegistry: .codingAgent,
        webSearcher: ChatControllerFakeSearcher(),
        webAccessSettingsProvider: {
          WebAccessSettings(policy: .off, provider: .duckDuckGo)
        }
      )
    )
    controller.loadSession(
      ChatSession(
        id: sessionID,
        selectedModelID: "gemma4-12b-qat-4bit",
        interactionMode: .chat
      ))
    controller.modelRuntime.modelState = .ready
    controller.sendMessage(prompt: "search Swift concurrency", in: workspace, sessionID: sessionID)

    try await waitUntil { !controller.isGenerating }

    let record = try #require(controller.chatSession.toolCalls.first)
    #expect(record.request.toolName == .webSearch)
    #expect(record.status == .denied)
  }

  @Test
  func sendMessageDisplaysShowFileResultDirectlyWithoutModelFollowUp() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appending(
      path: "sumika-tests-\(UUID().uuidString)",
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
          modeSettings: testModeSettings(
            systemPrompt: ChatPromptDefaults.agentSystemPrompt,
            generationSettings: .agentDefault
          )
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
    controller.sendMessage(
      prompt: "show the content of README.md", in: workspace, sessionID: sessionID)

    try await waitUntil { !controller.isGenerating }

    #expect(controller.errorMessage == nil)
    #expect(controller.chatSession.toolCalls.count == 1)
    #expect(controller.chatSession.testMessages.count == 3)
    #expect(controller.chatSession.testMessages[1].kind == .toolResult)
    #expect(controller.chatSession.testMessages[2].kind == .assistant)
    #expect(controller.chatSession.testMessages[2].content.contains("Here is `README.md`:"))
    #expect(controller.chatSession.testMessages[2].content.contains("1: project notes"))
    let projection = ChatModelContextBuilder().transcript(from: controller.chatSession)
    #expect(
      projection.entries.map(\.frozenContent.role) == [
        .user, .assistant, .tool, .assistant,
      ])
    #expect(
      projection.entries[2].frozenContent.content.contains(
        "Displayed file to user: README.md"))
    #expect(
      !projection.entries[2].frozenContent.content.contains(
        "1: project notes"))
    #expect(
      projection.entries[3].frozenContent.content
        == "Displayed show_file result for README.md directly to the user.")
    #expect(!projection.entries[3].frozenContent.content.contains("1: project notes"))
    #expect(controller.chatSession.focusedFileState == .empty)

    let capturedMessages = await runtime.capturedMessages
    #expect(capturedMessages.count == 1)
  }

  @Test
  func sendMessageKeepsToolCallHistoryWhenFollowUpResponseFails() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appending(
      path: "sumika-tests-\(UUID().uuidString)",
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
          modeSettings: testModeSettings(
            systemPrompt: ChatPromptDefaults.agentSystemPrompt,
            generationSettings: .agentDefault
          )
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
    controller.sendMessage(prompt: "Read the README", in: workspace, sessionID: sessionID)

    try await waitUntil { !controller.isGenerating }

    #expect(
      controller.errorMessage
        == ChatSessionFakeChatModelRuntimeError.streamFailed.localizedDescription)
    #expect(controller.chatSession.testMessages.count == 2)
    #expect(controller.chatSession.testMessages[1].toolCall?.toolName == .readFile)
    #expect(controller.chatSession.testMessages[1].content.isEmpty)
    #expect(controller.chatSession.testMessages[1].toolResult?.toolName == .readFile)
    #expect(controller.chatSession.testMessages[1].kind == .toolResult)
    #expect(
      !controller.chatSession.testMessages.contains { message in
        message.kind == .assistant && message.content.isEmpty
      })
  }

  @Test
  func refreshContextUsagePublishesEstimateWithoutRuntimeTokenization() async throws {
    let runtime = ControlledContextUsageRuntime()
    var session = ChatSession()
    session.testMessages = [TestTranscriptMessage(userContent: "hello")]
    let controller = ChatSessionController(
      runtime: runtime,
      modelPath: "/tmp/model",
      chatSession: session
    )
    controller.modelRuntime.modelState = .ready

    controller.refreshContextUsage()
    controller.refreshContextUsage()
    await Task.yield()

    #expect(controller.contextUsage?.accuracy == .estimate)
    #expect(controller.contextUsage?.isStale == false)
  }

  @Test
  func refreshContextUsageEstimatesWhileGeneratingWithoutDeferredTokenization() async throws {
    let runtime = ControlledStreamingRuntime(turns: [["done"]], blockedCallIndexes: [0])
    defer { Task { await runtime.releaseStream(callIndex: 0) } }
    let controller = ChatSessionController(runtime: runtime, modelPath: "/tmp/model")
    controller.modelRuntime.modelState = .ready
    controller.sendMessage(prompt: "Wait before answering")

    try await waitUntilAsync { await runtime.startedStreamCount == 1 }
    controller.refreshContextUsage()
    await Task.yield()

    #expect(controller.contextUsage?.accuracy == .estimate)
    #expect(controller.contextUsage?.isStale == false)

    await runtime.releaseStream(callIndex: 0)
    try await waitUntil { !controller.isGenerating }
    try await Task.sleep(for: .milliseconds(50))
  }

  @Test
  func clearChatHistoryDoesNotPublishStaleContextUsageAfterModelChange() async throws {
    let modelDirectory = try makeModelDirectory(config: #"{"n_ctx":2048}"#)
    let runtime = DelayedClearContextRuntime()
    defer { Task { await runtime.releaseClearContext() } }
    let controller = ChatSessionController(
      runtime: runtime,
      modelPath: modelDirectory.path(percentEncoded: false),
      chatSession: {
        var session = ChatSession()
        session.testMessages = [TestTranscriptMessage(userContent: "old session")]
        return session
      }()
    )
    controller.modelRuntime.modelState = .ready
    controller.contextUsage = ChatContextUsage(usedTokens: 12, tokenLimit: 128)

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
    timeout: Duration = .seconds(5),
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
    timeout: Duration = .seconds(5),
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
      path: "sumika-tests-\(UUID().uuidString)",
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
          modeSettings: testModeSettings(
            systemPrompt: ChatPromptDefaults.agentSystemPrompt,
            generationSettings: .agentDefault
          )
        )
      ]
    )
  }

  private func makeAttachment(
    name: String,
    kind: ChatAttachmentKind = .text
  ) -> ChatAttachment {
    ChatAttachment(
      url: URL(filePath: "/tmp/\(name)"),
      displayName: name,
      kind: kind,
      content: "fixture"
    )
  }

  private func makeToolCallRecord(status: ToolCallStatus) -> ToolCallRecord {
    ToolCallRecord(
      request: ToolCallRequest.validated(
        raw: RawToolCallRequest(
          workspaceID: UUID(),
          sessionID: UUID(),
          toolName: .listFiles
        ),
        payload: .listFiles(ListFilesInput(path: nil))
      ),
      evaluation: ToolPermissionEvaluation(
        decision: .allowed,
        reason: "Allowed for test.",
        riskLevel: .low
      ),
      state: toolCallState(status: status)
    )
  }

  private func toolCallState(status: ToolCallStatus) -> ToolCallState {
    switch status {
    case .pending:
      return .pending
    case .awaitingApproval:
      return .awaitingApproval(preview: nil)
    case .awaitingUserAnswer:
      return .awaitingUserAnswer
    case .running:
      return .running
    case .completed:
      return .completed(
        .listFiles(ListFilesResult(root: WorkspaceRelativePath(rawValue: "."), entries: [])))
    case .denied:
      return .denied(
        .failure(ToolFailure(toolName: .listFiles, path: nil, reason: .permissionDenied)))
    case .failed:
      return .failed(
        .failure(ToolFailure(toolName: .listFiles, path: nil, reason: .executionError("Failed."))))
    case .cancelled:
      return .cancelled
    }
  }

  private func makeModelDirectory(config: String) throws -> URL {
    let modelDirectory = FileManager.default.temporaryDirectory.appending(
      path: "sumika-tests-\(UUID().uuidString)",
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
    case .assistantThinking(let message):
      message.id
    case .assistantMessage(let message):
      message.id
    case .tool:
      nil
    }
  }
}

private struct ChatControllerFakeFetcher: WebFetching {
  func fetch(_ request: WebFetchRequest) async -> WebFetchToolResult {
    WebFetchToolResult(
      url: request.url.absoluteString,
      provider: request.settings.fetchProvider,
      finalURL: request.url.absoluteString,
      statusCode: 200,
      contentType: "text/plain",
      content: ToolTextOutput(text: "Fetched fixture text."),
      byteCount: 21
    )
  }
}

private struct ChatControllerFakeSearcher: WebSearching {
  func search(_ request: WebSearchRequest) async -> WebSearchToolResult {
    WebSearchToolResult(
      query: request.query,
      provider: request.settings.provider,
      results: [
        WebSearchResult(
          title: "Swift Documentation",
          url: "https://www.swift.org/documentation/",
          snippet: "Swift docs fixture."
        )
      ]
    )
  }
}
