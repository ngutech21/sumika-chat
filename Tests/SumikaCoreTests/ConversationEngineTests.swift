import Foundation
import Testing

@testable import SumikaCore

@Suite(.serialized)
@MainActor
struct ConversationEngineTests {
  @Test
  func releasingEngineReleasesTestModelComposition() async throws {
    weak var modelController: ModelRuntimeController?

    do {
      let engine = ConversationEngine(
        runtime: ChatSessionFakeChatModelRuntime(),
        modelPath: "/tmp/model"
      )
      modelController = engine.modelRuntime
      #expect(modelController != nil)
    }

    try await waitUntil(timeout: .seconds(1)) {
      modelController == nil
    }
  }

  @Test
  func canSendRequiresReadyModelNonEmptyPromptAndIdleGeneration() {
    let engine = ConversationEngine(
      runtime: ChatSessionFakeChatModelRuntime(),
      modelPath: "/tmp/model"
    )

    engine.modelRuntime.modelState = .ready

    #expect(engine.canSend(prompt: "  hello  "))

    #expect(!engine.canSend(prompt: "   "))

    engine.isGenerating = true
    #expect(!engine.canSend(prompt: "hello"))
  }

  @Test
  func canSendIgnoresPendingToolInteractions() {
    let approvalRecord = makeToolCallRecord(status: .awaitingApproval)
    let askUserRecord = makeToolCallRecord(status: .awaitingUserAnswer)
    let engine = ConversationEngine(
      runtime: ChatSessionFakeChatModelRuntime(),
      modelPath: "/tmp/model",
      chatSession: ChatSession(turns: [
        ChatTurn(status: .awaitingApproval, items: [.tool(approvalRecord)]),
        ChatTurn(status: .awaitingUserAnswer, items: [.tool(askUserRecord)]),
      ])
    )
    engine.modelRuntime.modelState = .ready

    #expect(engine.hasPendingApproval)
    #expect(engine.hasPendingUserAnswer)
    #expect(engine.canSend(prompt: "continue with a new instruction"))
  }

  @Test
  func interruptingPendingInteractionAppliesQueuedAgentToolConfiguration() async throws {
    let runtime = ChatSessionFakeChatModelRuntime(chunks: ["new answer"])
    let selectedServerID = UUID()
    let unselectedServerID = UUID()
    let selectedToolName = ToolName(rawValue: "mcp__selected__echo")
    let unselectedToolName = ToolName(rawValue: "mcp__unselected__echo")
    let approvalRecord = makeToolCallRecord(status: .awaitingApproval)
    let sessionID = UUID()
    let engine = ConversationEngine(
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
    engine.modelRuntime.modelState = .ready

    engine.reconcileAgentTools(
      todoWriteEnabled: false,
      mcpExecutorGroups: [
        makeMCPExecutorGroup(serverID: selectedServerID, serverSlug: "selected"),
        makeMCPExecutorGroup(serverID: unselectedServerID, serverSlug: "unselected"),
      ],
      selectedMCPServerIDs: [selectedServerID]
    )

    #expect(engine.chatSession.selectedMCPServerIDs.isEmpty)
    #expect(
      engine.sendMessage(
        prompt: "continue with the updated tools",
        in: workspace,
        sessionID: sessionID
      )
    )
    try await waitUntil { !engine.isGenerating }

    let capturedToolContexts = await runtime.capturedToolContexts
    let toolContext = try #require(capturedToolContexts.first ?? nil)
    #expect(toolContext.registry.definition(for: .readFile) != nil)
    #expect(toolContext.registry.definition(for: .editFile) != nil)
    #expect(toolContext.registry.definition(for: .todoWrite) == nil)
    #expect(toolContext.registry.definition(for: selectedToolName) != nil)
    #expect(toolContext.registry.definition(for: unselectedToolName) == nil)
    #expect(engine.chatSession.selectedMCPServerIDs == [selectedServerID])
  }

  @Test
  func composerSessionStateIgnoresTranscriptOnlyChanges() {
    let engine = ConversationEngine(
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
    let originalState = engine.composerSessionState

    engine.clearChatHistory()

    #expect(engine.composerSessionState == originalState)
  }

  @Test
  func composerSessionStateTracksComposerRelevantSessionFields() throws {
    let attachment = makeAttachment(name: "screenshot.png", kind: .image)
    let todoState = TodoState(items: [
      TodoItem(id: "1", content: "Inspect files", status: .completed),
      TodoItem(id: "2", content: "Run tests", status: .pending),
    ])
    let mcpServerID = UUID()
    let engine = ConversationEngine(
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

    #expect(engine.composerSessionState.pendingAttachments == [attachment])
    #expect(engine.composerSessionState.activeAttachments == [attachment])
    #expect(engine.composerSessionState.interactionMode == .chat)
    #expect(engine.composerSessionState.toolApprovalPolicy == .manual)
    #expect(engine.composerSessionState.selectedMCPServerIDs == [mcpServerID])
    #expect(engine.composerSessionState.todoState == nil)

    engine.setInteractionMode(.agent)
    engine.enableAutomaticToolApproval(
      in: try makeWorkspace(sessionID: engine.sessionID)
    )

    #expect(engine.composerSessionState.interactionMode == .agent)
    #expect(engine.composerSessionState.toolApprovalPolicy == .automatic)
    #expect(engine.composerSessionState.todoState == todoState)
  }

  @Test
  func mcpServerSelectionIsAgentOnlyAndBlockedDuringGeneration() {
    let engine = ConversationEngine(
      runtime: ChatSessionFakeChatModelRuntime(),
      modelPath: "/tmp/model"
    )
    let first = UUID()
    let second = UUID()

    #expect(!engine.canChangeMCPServerSelection)
    engine.setSelectedMCPServerIDs([first])
    #expect(engine.chatSession.selectedMCPServerIDs.isEmpty)

    engine.setInteractionMode(.agent)
    #expect(engine.canChangeMCPServerSelection)
    engine.setSelectedMCPServerIDs([first])
    #expect(engine.chatSession.selectedMCPServerIDs == [first])
    #expect(engine.composerSessionState.selectedMCPServerIDs == [first])

    engine.isGenerating = true
    engine.setSelectedMCPServerIDs([second])
    #expect(engine.chatSession.selectedMCPServerIDs == [first])
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
    let engine = ConversationEngine(
      runtime: ChatSessionFakeChatModelRuntime(),
      modelPath: "/tmp/model"
    )

    engine.loadSession(session)
    let snapshot = engine.sessionSnapshot()

    #expect(engine.chatSession.focusedFileState == focusedFileState)
    #expect(engine.chatSession.interactionMode == .agent)
    #expect(engine.chatSession.toolApprovalPolicy == .automatic)
    #expect(snapshot.focusedFileState == focusedFileState)
    #expect(snapshot.interactionMode == .agent)
    #expect(snapshot.toolApprovalPolicy == .automatic)
    #expect(snapshot.selectedMCPServerIDs == [mcpServerID])
  }

  @Test
  func sessionSnapshotCarriesLiveTodoState() {
    let engine = ConversationEngine(
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

    engine.loadSession(
      ChatSession(
        id: persisted.id,
        interactionMode: .agent,
        todoState: liveTodoState
      ))

    #expect(engine.sessionSnapshot().todoState == liveTodoState)

    engine.loadSession(
      ChatSession(
        id: persisted.id,
        interactionMode: .agent
      ))

    #expect(engine.sessionSnapshot().todoState == nil)
  }

  @Test
  func sessionSnapshotCopiesCompleteLiveSessionState() {
    let attachment = makeAttachment(name: "context.png", kind: .image)
    let activeAttachmentContext = ActiveAttachmentContext(
      attachmentIDs: [attachment.id]
    )
    let liveSession = ChatSession(
      title: "Live session",
      pendingAttachments: [attachment],
      focusedFileState: FocusedFileState(
        activePath: WorkspaceRelativePath(rawValue: "README.md")
      ),
      interactionMode: .agent,
      toolApprovalPolicy: .automatic,
      selectedMCPServerIDs: [UUID()],
      todoState: TodoState(items: [
        TodoItem(id: "1", content: "Run tests", status: .inProgress)
      ]),
      activeAttachmentContext: activeAttachmentContext
    )
    let engine = ConversationEngine(
      runtime: ChatSessionFakeChatModelRuntime(),
      modelPath: "/tmp/model",
      chatSession: liveSession
    )

    let snapshot = engine.sessionSnapshot()
    var expected = liveSession
    expected.selectedModelID = snapshot.selectedModelID
    expected.pendingAttachments = []
    expected.updatedAt = snapshot.updatedAt

    #expect(snapshot == expected)
    #expect(snapshot.activeAttachmentContext == activeAttachmentContext)
    #expect(snapshot.pendingAttachments.isEmpty)
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
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    engine.modelRuntime.modelState = .ready

    engine.loadSession(session)

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
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    engine.modelRuntime.modelState = .loading

    engine.loadSession(session)
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
    let engine = ConversationEngine(
      runtime: runtime,
      modelPath: "/tmp/model",
      chatSession: ChatSession(turns: [originalTurn])
    )
    let targetModel = try #require(ManagedModelCatalog.model(id: "gemma4-12b-qat-4bit"))
    engine.modelRuntime.modelState = .ready
    engine.modelRuntime.selectedModelID = "gemma4-26b-qat-4bit"
    engine.contextUsage = ChatContextUsage(usedTokens: 12, tokenLimit: 128)

    engine.modelRuntime.selectModel(targetModel)

    try await waitUntilAsync { await runtime.clearContextCount == 1 }
    let snapshot = engine.sessionSnapshot()
    #expect(engine.chatSession.turns == [originalTurn])
    #expect(snapshot.turns == [originalTurn])
    #expect(snapshot.selectedModelID == targetModel.id)
  }

  @Test
  func defaultsToChatInteractionMode() {
    let engine = ConversationEngine(
      runtime: ChatSessionFakeChatModelRuntime(),
      modelPath: "/tmp/model"
    )

    #expect(engine.chatSession.interactionMode == .chat)
  }

  @Test
  func automaticApprovalIsAgentOnlyRetainedAcrossModeChangesAndDisablesImmediately() throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let engine = ConversationEngine(
      runtime: ChatSessionFakeChatModelRuntime(),
      modelPath: "/tmp/model"
    )

    #expect(!engine.canEnableAutomaticToolApproval)
    engine.setInteractionMode(.agent)
    #expect(engine.canEnableAutomaticToolApproval)

    engine.enableAutomaticToolApproval(in: workspace)
    #expect(engine.chatSession.toolApprovalPolicy == .automatic)
    #expect(!engine.canEnableAutomaticToolApproval)

    engine.setInteractionMode(.chat)
    #expect(engine.chatSession.toolApprovalPolicy == .automatic)
    #expect(!engine.canEnableAutomaticToolApproval)

    engine.setInteractionMode(.agent)
    #expect(engine.chatSession.toolApprovalPolicy == .automatic)

    engine.disableAutomaticToolApproval()
    #expect(engine.chatSession.toolApprovalPolicy == .manual)
    #expect(engine.canEnableAutomaticToolApproval)

    engine.loadSession(
      ChatSession(
        id: engine.sessionID,
        turns: [
          ChatTurn(
            status: .awaitingApproval,
            items: [.tool(makeToolCallRecord(status: .awaitingApproval))]
          )
        ],
        interactionMode: .agent
      ))
    #expect(engine.canEnableAutomaticToolApproval)

    engine.loadSession(
      ChatSession(
        id: engine.sessionID,
        turns: [
          ChatTurn(
            status: .awaitingUserAnswer,
            items: [.tool(makeToolCallRecord(status: .awaitingUserAnswer))]
          )
        ],
        interactionMode: .agent
      ))
    #expect(!engine.canEnableAutomaticToolApproval)
  }

  @Test
  func loadSessionForExperimentalGemma4PreservesToolMode() {
    let session = ChatSession(
      selectedModelID: "gemma4-12b-qat-4bit",
      interactionMode: .agent
    )
    let engine = ConversationEngine(
      runtime: ChatSessionFakeChatModelRuntime(),
      modelPath: "/tmp/model"
    )

    engine.loadSession(session)

    #expect(engine.modelRuntime.selectedModelID == "gemma4-12b-qat-4bit")
    #expect(engine.chatSession.interactionMode == .agent)
    #expect(engine.errorMessage == nil)
  }

  @Test
  func setInteractionModeAllowsExperimentalGemma4ToolModes() {
    let session = ChatSession(selectedModelID: "gemma4-12b-qat-4bit")
    let engine = ConversationEngine(
      runtime: ChatSessionFakeChatModelRuntime(),
      modelPath: "/tmp/model"
    )
    engine.loadSession(session)

    engine.setInteractionMode(.agent)

    #expect(engine.chatSession.interactionMode == .agent)
    #expect(engine.errorMessage == nil)
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
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    engine.modelRuntime.modelState = .ready
    engine.updateModeSettings(
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

    #expect(engine.sendMessage(prompt: "hello"))
    try await waitUntilAsync { await runtime.capturedGenerationSettings.count == 1 }

    engine.setInteractionMode(.agent)
    #expect(engine.sendMessage(prompt: "inspect"))
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
    let engine = ConversationEngine(
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

    engine.setReasoningEnabled(false)

    #expect(!engine.chatSession.modeSettings.chat.generationSettings.reasoningEnabled)
    #expect(engine.chatSession.modeSettings.agent.generationSettings.reasoningEnabled)
    #expect(!engine.composerSessionState.reasoningEnabled)
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
    let engine = ConversationEngine(
      runtime: ChatSessionFakeChatModelRuntime(),
      modelPath: "/tmp/model"
    )
    engine.loadSession(session)
    let workspace = Workspace(
      name: "Project",
      rootURL: URL(filePath: "/tmp/project"),
      sessions: [engine.chatSession]
    )

    let unavailableDocument = try engine.modelContextDebugDocument()
    let availableDocument = try engine.modelContextDebugDocument(
      workspace: workspace,
      sessionID: engine.chatSession.id
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
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    let initialRevision = engine.modelContextDebugState.documentRevision

    engine.loadSession(ChatSession(selectedModelID: ManagedModelCatalog.defaultModelID))

    #expect(engine.modelContextDebugState.documentRevision > initialRevision)

    engine.modelRuntime.modelState = .ready
    engine.sendMessage(prompt: "hello")

    try await waitUntil { engine.modelContextDebugState.runtimeCacheDebugSnapshot == snapshot }

    let revisionAfterSend = engine.modelContextDebugState.documentRevision
    engine.clearChatHistory()

    #expect(engine.modelContextDebugState.runtimeCacheDebugSnapshot == nil)
    #expect(engine.modelContextDebugState.documentRevision > revisionAfterSend)
  }

  @Test
  func sendMessageAllowsExperimentalGemma4PersistedToolMode() async throws {
    let runtime = ChatSessionFakeChatModelRuntime(chunks: ["native mode response"])
    let engine = ConversationEngine(
      runtime: runtime,
      modelPath: "/tmp/model",
      chatSession: ChatSession(
        selectedModelID: "gemma4-12b-qat-4bit",
        interactionMode: .agent
      )
    )
    engine.modelRuntime.modelState = .ready
    engine.sendMessage(prompt: "inspect files")
    try await waitUntil { !engine.isGenerating }

    #expect(!engine.chatSession.turns.isEmpty)
    #expect(engine.errorMessage == nil)
  }

  @Test
  func sendMessageNamesDefaultSessionFromFirstPrompt() async throws {
    let runtime = ChatSessionFakeChatModelRuntime(chunks: ["done"])
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    let session = ChatSession(selectedModelID: ManagedModelCatalog.defaultModelID)
    engine.loadSession(session)
    engine.modelRuntime.modelState = .ready
    engine.sendMessage(prompt: "  build   a snake game\nin python  ")
    try await waitUntil { !engine.isGenerating }

    #expect(engine.chatSession.title == "build a snake game in python")
    #expect(engine.sessionSnapshot().title == "build a snake game in python")
  }

  @Test
  func renameSessionNormalizesTitleAndNotifiesChange() {
    let engine = ConversationEngine(
      runtime: ChatSessionFakeChatModelRuntime(),
      modelPath: "/tmp/model"
    )
    var changeCount = 0
    engine.setSessionChangeHandler {
      changeCount += 1
    }

    #expect(engine.renameSession(to: "  Manual title  "))
    #expect(engine.chatSession.title == "Manual title")
    #expect(changeCount == 1)
    #expect(!engine.renameSession(to: "   "))
    #expect(engine.chatSession.title == "Manual title")
    #expect(changeCount == 1)
  }

  @Test
  func sendMessageDoesNotRenameManualTitle() async throws {
    let runtime = ChatSessionFakeChatModelRuntime(chunks: ["done"])
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    engine.loadSession(
      ChatSession(
        title: "Manual title",
        selectedModelID: ManagedModelCatalog.defaultModelID
      )
    )
    engine.modelRuntime.modelState = .ready
    engine.sendMessage(prompt: "first prompt")
    try await waitUntil { !engine.isGenerating }

    #expect(engine.chatSession.title == "Manual title")
  }

  @Test
  func sendMessageDoesNotRenameExistingConversation() async throws {
    let runtime = ChatSessionFakeChatModelRuntime(chunks: ["done"])
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    let existingTurn = ChatTurn(
      status: .completed,
      items: [.userMessage(UserTurnMessage(content: "original prompt"))]
    )
    engine.loadSession(
      ChatSession(
        selectedModelID: ManagedModelCatalog.defaultModelID,
        turns: [existingTurn]
      )
    )
    engine.modelRuntime.modelState = .ready
    engine.sendMessage(prompt: "second prompt")
    try await waitUntil { !engine.isGenerating }

    #expect(engine.chatSession.title == ChatSession.defaultTitle)
  }

  @Test
  func sendMessageDoesNotFreezeBaseSystemPromptIntoUserEntriesAcrossTurns() async throws {
    let runtime = ChatSessionFakeChatModelRuntime(eventTurns: [
      [.chunk("first answer")],
      [.chunk("second answer")],
    ])
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    engine.loadSession(
      ChatSession(
        selectedModelID: "gemma4-12b-qat-4bit",
        modeSettings: testModeSettings(
          systemPrompt: "Base system prompt",
          generationSettings: .chatDefault
        )
      ))
    engine.modelRuntime.modelState = .ready

    engine.sendMessage(prompt: "first")
    try await waitUntil { !engine.isGenerating }

    engine.sendMessage(prompt: "second")
    try await waitUntil { !engine.isGenerating }

    let projection = ChatModelContextBuilder().transcript(from: engine.chatSession)
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
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")

    engine.setInteractionMode(.agent)

    try await waitUntilAsync { await runtime.clearContextCount == 1 }
  }

  @Test
  func sendMessageWaitsForPendingRuntimeContextClear() async throws {
    let runtime = DelayedClearContextRuntime()
    defer { Task { await runtime.releaseClearContext() } }
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    engine.modelRuntime.modelState = .ready

    engine.setInteractionMode(.agent)
    try await waitUntilAsync { await runtime.didStartClearContext }

    engine.sendMessage(prompt: "hello")
    await Task.yield()

    #expect(await runtime.streamReplyCount == 0)

    await runtime.releaseClearContext()

    try await waitUntilAsync { await runtime.streamReplyCount == 1 }
    try await waitUntil { !engine.isGenerating }
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
    let engine = ConversationEngine(
      runtime: runtime,
      modelPath: "/tmp/model",
      chatSession: ChatSession(pendingAttachments: [attachment])
    )
    engine.modelRuntime.modelState = .ready

    engine.sendMessage(prompt: "Explain this")

    try await waitUntil { !engine.isGenerating }

    #expect(engine.chatSession.pendingAttachments.isEmpty)
    #expect(engine.chatSession.testMessages.count == 2)
    #expect(engine.chatSession.testMessages[0].kind == .user)
    #expect(engine.chatSession.testMessages[0].content == "Explain this")
    #expect(engine.chatSession.testMessages[0].attachments == [attachment])
    #expect(engine.chatSession.testMessages[1].kind == .assistant)
    #expect(engine.chatSession.testMessages[1].content == "hello world")
    #expect(engine.chatSession.testMessages[1].deliveryStatus == .complete)
    #expect(
      engine.chatSession.focusedFileState.activePath
        == WorkspaceRelativePath(rawValue: "source.swift"))
    #expect(engine.chatSession.focusedFileState.recentPaths.first?.source == .attachment)
    #expect(
      engine.chatSession.focusedFileState.snapshots[
        WorkspaceRelativePath(rawValue: "source.swift")]?.excerpt == "let value = 1")
    #expect(engine.chatSession.turns.count == 1)
    #expect(engine.chatSession.turns[0].status == .completed)
    #expect(engine.chatSession.turns[0].modelContextPolicy == .included)
    #expect(
      engine.chatSession.turns[0].items.map(messageID)
        == engine.chatSession.testMessages.map(\.id)
    )
    let generationMetrics = try #require(engine.chatSession.testMessages[1].generationMetrics)
    #expect(generationMetrics.generatedTokenCount == 2)
    #expect(generationMetrics.tokensPerSecond == 100)
    #expect(generationMetrics.durationMs > 0)
    let capturedMessages = await runtime.capturedMessages
    #expect(await runtime.capturedAttachments == [[attachment]])
    #expect(
      capturedMessages.first?.contains(where: { message in
        message.role == .user && message.content.contains("Attached file: source.swift")
      }) == true)
    let projection = ChatModelContextBuilder().transcript(from: engine.chatSession)
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
    let engine = ConversationEngine(
      runtime: runtime,
      modelPath: "/tmp/model",
      chatSession: ChatSession(
        selectedModelID: "gemma4-12b-qat-4bit",
        pendingAttachments: [attachment]
      )
    )
    engine.modelRuntime.modelState = .ready

    engine.sendMessage(prompt: "What is in this screenshot?")

    try await waitUntil { !engine.isGenerating }

    #expect(await runtime.capturedAttachments == [[attachment]])
    #expect(engine.chatSession.pendingAttachments.isEmpty)
    #expect(engine.chatSession.testMessages[0].attachments == [attachment])
  }

  @Test
  func cancelGenerationStopsControllerAndDropsTransientAssistantPlaceholder() async throws {
    let runtime = NonCooperativeStreamingRuntime(chunks: ["late reply"])
    defer { Task { await runtime.releaseChunks() } }
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    engine.modelRuntime.modelState = .ready
    engine.sendMessage(prompt: "Cancel this")

    try await waitUntilAsync { await runtime.didStartStreaming }
    engine.cancelGeneration()
    await runtime.releaseChunks()

    try await waitUntilAsync { await runtime.didFinishStreaming }
    try await waitUntil { !engine.isGenerating }

    #expect(!engine.isGenerating)
    #expect(engine.chatSession.testMessages.count == 1)
    #expect(engine.chatSession.testMessages.first?.kind == .user)
    #expect(engine.chatSession.testMessages.first?.content == "Cancel this")
    #expect(engine.chatSession.turns.count == 1)
    #expect(engine.chatSession.turns[0].status == .cancelled)
    #expect(engine.chatSession.turns[0].modelContextPolicy == .excluded)
    let persistedItems = engine.chatSession.turns[0].items
    #expect(persistedItems.count == 2)
    #expect(persistedItems[0].messageID == engine.chatSession.testMessages[0].id)
    #expect(persistedItems[1].kindForTesting == .assistant)
    #expect(persistedItems[1].contentForTesting.isEmpty)
    #expect(persistedItems[1].deliveryStatusForTesting == .cancelled)
    #expect(engine.errorMessage == nil)
  }

  @Test
  func switchingSessionCancelsOldTurnBeforeApplyingNewModelAndSession() async throws {
    let runtime = NonCooperativeStreamingRuntime(chunks: ["late reply"])
    defer { Task { await runtime.releaseChunks() } }
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    let targetModel = try #require(ManagedModelCatalog.model(id: "gemma4-26b-qat-4bit"))
    let targetSession = ChatSession(selectedModelID: targetModel.id)
    engine.modelRuntime.modelState = .ready
    engine.sendMessage(prompt: "Do not leak this reply")

    try await waitUntilAsync { await runtime.didStartStreaming }

    ConversationSessionCoordinator(
      modelController: engine.modelRuntime,
      conversationEngine: engine
    ).switchSession(to: targetSession)

    #expect(!engine.isGenerating)
    #expect(engine.modelRuntime.selectedModelID == targetModel.id)
    #expect(engine.modelRuntime.modelState == .notLoaded)
    #expect(engine.chatSession.id == targetSession.id)
    #expect(engine.chatSession.turns.isEmpty)

    await runtime.releaseChunks()
    try await waitUntilAsync { await runtime.didFinishStreaming }

    #expect(engine.chatSession.id == targetSession.id)
    #expect(engine.chatSession.turns.isEmpty)
  }

  @Test
  func failedStreamWithPartialOutputDoesNotLeaveAssistantMessageStreaming() async throws {
    let runtime = PartialFailingStreamingRuntime(chunks: ["partial answer"])
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    engine.modelRuntime.modelState = .ready
    engine.sendMessage(prompt: "fail after partial output")

    try await waitUntil { !engine.isGenerating }

    #expect(engine.chatSession.turns.count == 1)
    #expect(engine.chatSession.turns[0].status == .failed)
    #expect(engine.chatSession.turns[0].modelContextPolicy == .excluded)
    #expect(engine.chatSession.testMessages.count == 2)
    #expect(engine.chatSession.testMessages[1].kind == .assistant)
    #expect(engine.chatSession.testMessages[1].content == "partial answer")
    #expect(engine.chatSession.testMessages[1].deliveryStatus == .cancelled)
    #expect(
      engine.errorMessage
        == ChatSessionFakeChatModelRuntimeError.streamFailed.localizedDescription)
  }

  @Test
  func interruptedStreamDoesNotLeaveAssistantMessageStreaming() async throws {
    let runtime = InterruptedStreamingRuntime(chunks: [])
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    engine.modelRuntime.modelState = .ready
    engine.sendMessage(prompt: "stream ends without completion")

    try await waitUntil { !engine.isGenerating }

    #expect(engine.chatSession.turns.count == 1)
    #expect(engine.chatSession.turns[0].status == .failed)
    #expect(engine.chatSession.turns[0].modelContextPolicy == .excluded)
    #expect(engine.chatSession.testMessages.count == 1)
    #expect(engine.chatSession.testMessages[0].kind == .user)
    #expect(engine.errorMessage == ChatGenerationError.streamInterrupted.localizedDescription)
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
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    engine.modelRuntime.modelState = .ready
    engine.setInteractionMode(.agent)
    engine.sendMessage(
      prompt: "read README.md before answering", in: workspace, sessionID: sessionID)
    try await waitUntilAsync { await runtime.startedStreamCount == 2 }
    try await waitUntil { engine.chatSession.testMessages.contains { $0.kind == .toolResult } }

    engine.cancelGeneration()
    await runtime.releaseStream(callIndex: 1)
    try await waitUntil { !engine.isGenerating }

    #expect(engine.chatSession.toolCalls.count == 1)
    #expect(engine.chatSession.toolCalls[0].status == .completed)
    let toolMessage = try #require(
      engine.chatSession.testMessages.first { $0.kind == .toolResult })
    #expect(toolMessage.toolCall?.toolName == .readFile)
    #expect(toolMessage.toolResult?.toolName == .readFile)
    #expect(engine.chatSession.turns.count == 1)
    #expect(engine.chatSession.turns[0].status == .cancelled)
    #expect(engine.chatSession.turns[0].modelContextPolicy == .excluded)

    engine.sendMessage(prompt: "are you there", in: workspace, sessionID: sessionID)
    try await waitUntil { !engine.isGenerating }

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
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    engine.modelRuntime.modelState = .ready
    engine.sendMessage(prompt: "first")
    try await waitUntilAsync { await runtime.startedStreamCount == 1 }
    engine.cancelGeneration()

    engine.sendMessage(prompt: "second")
    try await waitUntilAsync { await runtime.startedStreamCount == 2 }

    await runtime.releaseStream(callIndex: 0)
    try await waitUntilAsync { await runtime.completedCallIndexes.contains(0) }
    #expect(engine.isGenerating)
    #expect(engine.chatSession.turns.count == 2)
    #expect(engine.chatSession.turns[0].status == .cancelled)
    #expect(engine.chatSession.turns[1].status == .running)

    await runtime.releaseStream(callIndex: 1)
    try await waitUntil { !engine.isGenerating }
    #expect(engine.chatSession.turns[1].status == .completed)
    #expect(engine.chatSession.testMessages.last?.content == "second answer")
  }

  @Test
  func sendMessageInWorkspaceKeepsNormalChatFreeOfToolExecutionWithoutAction() async throws {
    let sessionID = UUID()
    let workspace = try makeWorkspace(sessionID: sessionID)
    let runtime = ChatSessionFakeChatModelRuntime(chunks: ["a short poem"])
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    engine.modelRuntime.modelState = .ready
    engine.sendMessage(prompt: "write a short poem", in: workspace, sessionID: sessionID)

    try await waitUntil { !engine.isGenerating }

    #expect(engine.errorMessage == nil)
    #expect(engine.chatSession.toolCalls.isEmpty)
    #expect(engine.chatSession.testMessages.count == 2)
    #expect(engine.chatSession.testMessages[1].content == "a short poem")

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
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    engine.modelRuntime.modelState = .ready
    engine.setInteractionMode(.agent)
    engine.sendMessage(prompt: "Fix the failing test", in: workspace, sessionID: sessionID)

    try await waitUntil { !engine.isGenerating }

    #expect(engine.errorMessage == nil)
    #expect(engine.chatSession.toolCalls.isEmpty)

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
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    engine.modelRuntime.modelState = .ready
    engine.sendMessage(
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

    try await waitUntil { !engine.isGenerating }

    #expect(engine.errorMessage == nil)
    #expect(engine.chatSession.toolCalls.isEmpty)
    #expect(engine.chatSession.testMessages.count == 2)
    #expect(engine.chatSession.testMessages[0].kind == .user)
    #expect(engine.chatSession.testMessages[0].toolResult == nil)
    #expect(engine.chatSession.testMessages[1].kind == .assistant)
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
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    engine.modelRuntime.modelState = .ready
    engine.setInteractionMode(.agent)
    engine.sendMessage(
      prompt: "lies die projektbeschreibung", in: workspace, sessionID: sessionID)

    try await waitUntil { !engine.isGenerating }

    #expect(engine.chatSession.toolCalls.count == 1)
    #expect(engine.chatSession.toolCalls[0].status == .completed)
    #expect(engine.chatSession.toolCalls[0].resultPreview?.text == "1: project notes")
    #expect(
      engine.chatSession.focusedFileState.activePath
        == WorkspaceRelativePath(rawValue: "README.md"))
    #expect(engine.chatSession.focusedFileState.recentPaths.first?.source == .readFile)
    #expect(
      engine.chatSession.focusedFileState.snapshots[
        WorkspaceRelativePath(rawValue: "README.md")]?.excerpt == "1: project notes")
    let callID = engine.chatSession.toolCalls[0].request.id
    #expect(engine.chatSession.testMessages.count == 3)
    #expect(engine.chatSession.testMessages[1].kind == .toolResult)
    #expect(engine.chatSession.testMessages[1].content.isEmpty)
    #expect(engine.chatSession.testMessages[1].toolCall?.callID == callID)
    #expect(engine.chatSession.testMessages[1].toolCall?.toolName == .readFile)
    #expect(engine.chatSession.testMessages[1].generationMetrics == nil)
    #expect(
      engine.chatSession.testMessages[1].toolCall?.arguments == [
        ToolCallModelArgument(name: "path", value: "README.md")
      ]
    )
    #expect(engine.chatSession.testMessages[1].toolResult?.callID == callID)
    #expect(engine.chatSession.testMessages[1].toolResult?.toolName == .readFile)
    #expect(engine.chatSession.testMessages[1].toolResult?.preview.status == .success)
    #expect(engine.chatSession.testMessages[1].toolResult?.preview.text == "1: project notes")
    #expect(engine.chatSession.testMessages[2].content == "The README says project notes.")
    let projection = ChatModelContextBuilder().transcript(from: engine.chatSession)
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
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    engine.loadSession(
      ChatSession(
        id: sessionID,
        selectedModelID: "gemma4-12b-qat-4bit",
        interactionMode: .agent
      ))
    engine.modelRuntime.modelState = .ready
    engine.sendMessage(prompt: "summarize the README", in: workspace, sessionID: sessionID)

    try await waitUntil { !engine.isGenerating }

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
    let toolCallID = try #require(engine.chatSession.toolCalls.first?.id)
    #expect(
      engine.chatSession.turnID(containingToolCall: toolCallID)
        == engine.chatSession.turns.first?.id)
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
    let engine = ConversationEngine(
      runtime: runtime,
      modelPath: "/tmp/model",
      toolOrchestrator: orchestrator
    )
    engine.loadSession(
      ChatSession(
        id: sessionID,
        selectedModelID: "gemma4-12b-qat-4bit",
        interactionMode: .agent
      ))
    engine.modelRuntime.modelState = .ready
    engine.sendMessage(
      prompt: "read and summarize this article https://example.com/article", in: workspace,
      sessionID: sessionID)

    try await waitUntil { !engine.isGenerating }

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
    let toolCallID = try #require(engine.chatSession.toolCalls.first?.id)
    #expect(
      engine.chatSession.turnID(containingToolCall: toolCallID)
        == engine.chatSession.turns.first?.id)
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
    let engine = ConversationEngine(
      runtime: runtime,
      modelPath: "/tmp/model",
      toolOrchestrator: orchestrator
    )
    engine.loadSession(
      ChatSession(
        id: sessionID,
        selectedModelID: "gemma4-12b-qat-4bit",
        interactionMode: .chat
      ))
    engine.modelRuntime.modelState = .ready
    engine.sendMessage(
      prompt: "what is current in Swift concurrency?", in: workspace, sessionID: sessionID)

    try await waitUntil { !engine.isGenerating }

    let record = try #require(engine.chatSession.toolCalls.first)
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
    let engine = ConversationEngine(
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
    engine.loadSession(
      ChatSession(
        id: sessionID,
        selectedModelID: "gemma4-12b-qat-4bit",
        interactionMode: .chat
      ))
    engine.modelRuntime.modelState = .ready
    engine.sendMessage(
      prompt: "research Swift concurrency", in: workspace, sessionID: sessionID)

    try await waitUntil { !engine.isGenerating }

    #expect(engine.chatSession.turns.first?.status == .completed)
    #expect(
      engine.chatSession.testMessages.last?.content
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
    let engine = ConversationEngine(
      runtime: runtime,
      modelPath: "/tmp/model",
      toolOrchestrator: orchestrator
    )
    engine.loadSession(
      ChatSession(
        id: sessionID,
        selectedModelID: "gemma4-12b-qat-4bit",
        interactionMode: .chat
      ))
    engine.modelRuntime.modelState = .ready
    engine.sendMessage(
      prompt: "read and summarize this article https://example.com/article",
      in: workspace,
      sessionID: sessionID
    )

    try await waitUntil { !engine.isGenerating }

    let record = try #require(engine.chatSession.toolCalls.first)
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
    let engine = ConversationEngine(
      runtime: runtime,
      modelPath: "/tmp/model",
      toolOrchestrator: ToolOrchestrator(
        executorRegistry: .codingAgent,
        webAccessSettingsProvider: {
          WebAccessSettings(policy: .allow, provider: .duckDuckGo)
        }
      )
    )
    engine.loadSession(
      ChatSession(
        id: sessionID,
        selectedModelID: "gemma4-12b-qat-4bit",
        interactionMode: .chat
      ))
    engine.modelRuntime.modelState = .ready
    engine.sendMessage(prompt: "read README.md", in: workspace, sessionID: sessionID)

    try await waitUntil { !engine.isGenerating }

    let record = try #require(engine.chatSession.toolCalls.first)
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
    let engine = ConversationEngine(
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
    engine.loadSession(
      ChatSession(
        id: sessionID,
        selectedModelID: "gemma4-12b-qat-4bit",
        interactionMode: .chat
      ))
    engine.modelRuntime.modelState = .ready
    engine.sendMessage(
      prompt: "fetch https://example.com/article", in: workspace, sessionID: sessionID)

    try await waitUntil { engine.chatSession.turns.first?.status == .awaitingApproval }
    let pending = try #require(engine.chatSession.toolCalls.first)
    #expect(pending.status == .awaitingApproval)
    #expect(pending.approvalPreview?.text.contains("Web fetch requires approval") == true)

    engine.setInteractionMode(.agent)
    #expect(engine.chatSession.interactionMode == .chat)

    engine.approveToolCall(id: pending.id, in: workspace)
    try await waitUntil { !engine.isGenerating }

    #expect(engine.chatSession.toolCalls.count == 2)
    #expect(engine.chatSession.toolCalls.first?.status == .completed)
    let blockedRead = try #require(engine.chatSession.toolCalls.last)
    #expect(blockedRead.request.toolName == .readFile)
    #expect(blockedRead.status == .failed)
    #expect(
      blockedRead.resultPreview?.text.contains(
        "Tool is not available in the active registry: read_file."
      ) == true)
    #expect(engine.chatSession.testMessages.last?.content == "Approved fetch completed.")
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
    let engine = ConversationEngine(
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
    engine.loadSession(
      ChatSession(
        id: sessionID,
        selectedModelID: "gemma4-12b-qat-4bit",
        interactionMode: .chat
      ))
    engine.modelRuntime.modelState = .ready
    engine.sendMessage(prompt: "search Swift concurrency", in: workspace, sessionID: sessionID)

    try await waitUntil { !engine.isGenerating }

    let record = try #require(engine.chatSession.toolCalls.first)
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
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    engine.modelRuntime.modelState = .ready
    engine.setInteractionMode(.agent)
    engine.sendMessage(
      prompt: "show the content of README.md", in: workspace, sessionID: sessionID)

    try await waitUntil { !engine.isGenerating }

    #expect(engine.errorMessage == nil)
    #expect(engine.chatSession.toolCalls.count == 1)
    #expect(engine.chatSession.testMessages.count == 3)
    #expect(engine.chatSession.testMessages[1].kind == .toolResult)
    #expect(engine.chatSession.testMessages[2].kind == .assistant)
    #expect(engine.chatSession.testMessages[2].content.contains("Here is `README.md`:"))
    #expect(engine.chatSession.testMessages[2].content.contains("1: project notes"))
    let projection = ChatModelContextBuilder().transcript(from: engine.chatSession)
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
    #expect(engine.chatSession.focusedFileState == .empty)

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
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    engine.modelRuntime.modelState = .ready
    engine.setInteractionMode(.agent)
    engine.sendMessage(prompt: "Read the README", in: workspace, sessionID: sessionID)

    try await waitUntil { !engine.isGenerating }

    #expect(
      engine.errorMessage
        == ChatSessionFakeChatModelRuntimeError.streamFailed.localizedDescription)
    #expect(engine.chatSession.testMessages.count == 2)
    #expect(engine.chatSession.testMessages[1].toolCall?.toolName == .readFile)
    #expect(engine.chatSession.testMessages[1].content.isEmpty)
    #expect(engine.chatSession.testMessages[1].toolResult?.toolName == .readFile)
    #expect(engine.chatSession.testMessages[1].kind == .toolResult)
    #expect(
      !engine.chatSession.testMessages.contains { message in
        message.kind == .assistant && message.content.isEmpty
      })
  }

  @Test
  func refreshContextUsagePublishesEstimateWithoutRuntimeTokenization() async throws {
    let runtime = ControlledContextUsageRuntime()
    var session = ChatSession()
    session.testMessages = [TestTranscriptMessage(userContent: "hello")]
    let engine = ConversationEngine(
      runtime: runtime,
      modelPath: "/tmp/model",
      chatSession: session
    )
    engine.modelRuntime.modelState = .ready

    engine.refreshContextUsage()
    engine.refreshContextUsage()
    await Task.yield()

    #expect(engine.contextUsage?.accuracy == .estimate)
    #expect(engine.contextUsage?.isStale == false)
  }

  @Test
  func refreshContextUsageEstimatesWhileGeneratingWithoutDeferredTokenization() async throws {
    let runtime = ControlledStreamingRuntime(turns: [["done"]], blockedCallIndexes: [0])
    defer { Task { await runtime.releaseStream(callIndex: 0) } }
    let engine = ConversationEngine(runtime: runtime, modelPath: "/tmp/model")
    engine.modelRuntime.modelState = .ready
    engine.sendMessage(prompt: "Wait before answering")

    try await waitUntilAsync { await runtime.startedStreamCount == 1 }
    engine.refreshContextUsage()
    await Task.yield()

    #expect(engine.contextUsage?.accuracy == .estimate)
    #expect(engine.contextUsage?.isStale == false)

    await runtime.releaseStream(callIndex: 0)
    try await waitUntil { !engine.isGenerating }
    try await Task.sleep(for: .milliseconds(50))
  }

  @Test
  func clearChatHistoryDoesNotPublishStaleContextUsageAfterModelChange() async throws {
    let modelDirectory = try makeModelDirectory(config: #"{"n_ctx":2048}"#)
    let runtime = DelayedClearContextRuntime()
    defer { Task { await runtime.releaseClearContext() } }
    let engine = ConversationEngine(
      runtime: runtime,
      modelPath: modelDirectory.path(percentEncoded: false),
      chatSession: {
        var session = ChatSession()
        session.testMessages = [TestTranscriptMessage(userContent: "old session")]
        return session
      }()
    )
    engine.modelRuntime.modelState = .ready
    engine.contextUsage = ChatContextUsage(usedTokens: 12, tokenLimit: 128)

    engine.clearChatHistory()
    try await waitUntilAsync { await runtime.didStartClearContext }

    engine.prepareForModelRuntimeAction(cancelGeneration: false, invalidateContext: true)
    engine.modelRuntime.loadModel()
    try await waitUntil { engine.contextUsage?.usedTokens != 12 }

    await runtime.releaseClearContext()
    try await waitUntilAsync { await runtime.didFinishClearContext }
    try await waitUntil(timeout: .seconds(2)) { engine.modelRuntime.modelState == .ready }

    #expect(engine.modelRuntime.modelState == .ready)
    #expect(engine.contextUsage?.usedTokens != 12)
  }

  @Test
  func staleAttachmentLoadDoesNotAppendAfterNewerAttachmentRequest() async throws {
    let loader = BlockingFirstAttachmentLoader()
    defer { loader.releaseFirstLoad() }
    let engine = ConversationEngine(
      runtime: ChatSessionFakeChatModelRuntime(),
      modelPath: "/tmp/model",
      chatAttachmentLoader: loader
    )

    engine.addAttachments(from: [URL(filePath: "/tmp/first.swift")])
    try await waitUntil { loader.startedCount == 1 }

    engine.addAttachments(from: [URL(filePath: "/tmp/second.swift")])
    try await waitUntil {
      engine.chatSession.pendingAttachments.map(\.displayName) == ["second.swift"]
    }

    loader.releaseFirstLoad()
    try await waitUntil { loader.completedCount == 2 }
    await Task.yield()

    #expect(engine.chatSession.pendingAttachments.map(\.displayName) == ["second.swift"])
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

private struct ConversationEngineMCPToolClient: MCPToolCalling {
  func callTool(
    serverID: UUID,
    connectionToken: UUID,
    name: String,
    arguments: ToolCallArguments
  ) async throws -> MCPToolResult {
    _ = serverID
    _ = connectionToken
    _ = name
    _ = arguments
    throw CancellationError()
  }
}

private func makeMCPExecutorGroup(
  serverID: UUID,
  serverSlug: String
) -> MCPAgentToolExecutorGroup {
  MCPAgentToolExecutorGroup(
    serverID: serverID,
    executors: [
      AnyToolExecutor(
        dynamic: MCPToolExecutor(
          serverID: serverID,
          connectionToken: UUID(),
          serverName: serverSlug,
          serverSlug: serverSlug,
          remoteTool: MCPRemoteTool(
            name: "echo",
            description: "Echo a value."
          ),
          client: ConversationEngineMCPToolClient()
        )
      )
    ]
  )
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
