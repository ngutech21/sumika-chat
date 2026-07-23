import Foundation
import Testing

@testable import SumikaCore

struct ChatWorkflowEventApplierTests {
  @Test
  func updatesPromptContextOnAlreadyAppendedUserMessage() throws {
    let messageID = UUID()
    let snapshot = try #require(
      WorkspaceInstructionsPromptContext.makeSnapshot(
        path: WorkspaceRelativePath(rawValue: "AGENTS.md"),
        contentHash: String(repeating: "a", count: 64),
        content: "Use just test-core."
      )
    )
    let promptContext = CurrentPromptContext.empty(.focusedFileDefault)
      .appendingWorkspaceInstructions(snapshot)
    var state = makeState(items: [
      .userMessage(UserTurnMessage(id: messageID, content: "Implement"))
    ])

    let diagnostics = ChatWorkflowEventApplier().apply(
      .userMessagePromptContextUpdated(
        messageID: messageID,
        promptContext: promptContext
      ),
      to: &state
    )

    #expect(diagnostics.isEmpty)
    guard case .userMessage(let message) = state.turns[0].items[0] else {
      Issue.record("Expected the user message to remain in place.")
      return
    }
    #expect(message.id == messageID)
    #expect(message.promptContext == promptContext)
  }

  @Test
  func nativeMultipleToolCallAnnotationsDoNotReportMissingMessageAfterFirstUpdate() {
    let assistantID = UUID()
    let readCall = ToolCallModelMessage(
      callID: UUID(),
      toolName: .readFile,
      arguments: [ToolCallModelArgument(name: "path", value: "README.md")]
    )
    let editCall = ToolCallModelMessage(
      callID: UUID(),
      toolName: .editFile,
      arguments: [ToolCallModelArgument(name: "path", value: "README.md")]
    )
    var state = makeState(items: [
      .assistantMessage(AssistantTurnMessage(id: assistantID, content: "I'll use tools."))
    ])

    let diagnostics = ChatWorkflowEventApplier().apply(
      [
        .assistantAnnotatedAsNativeToolCall(
          assistantMessageID: assistantID,
          toolCall: readCall
        ),
        .assistantAnnotatedAsNativeToolCall(
          assistantMessageID: assistantID,
          toolCall: editCall
        ),
      ],
      to: &state
    )

    #expect(diagnostics.isEmpty)
    #expect(state.toolCalls.map(\.id) == [readCall.callID, editCall.callID])
  }

  @Test
  func appendsToolCallAndRegistersItOnTurn() {
    let turnID = UUID()
    let record = makeToolCallRecord(status: .completed)
    var state = makeState(turns: [ChatTurn(id: turnID, status: .running)])

    ChatWorkflowEventApplier().apply(
      [.toolCallAppended(record, turnID: turnID)],
      to: &state
    )

    #expect(state.toolCalls == [record])
    #expect(state.turns[0].items == [.tool(record)])
    #expect(state.turnID(containingToolCall: record.id) == turnID)
  }

  @Test
  func updatesExistingToolCallRecord() {
    let existing = makeToolCallRecord(status: .awaitingApproval)
    let updated = makeToolCallRecord(request: existing.request, status: .completed)
    var state = makeState(items: [.tool(existing)])

    ChatWorkflowEventApplier().apply(
      [.toolCallUpdated(updated)],
      to: &state
    )

    #expect(state.toolCalls == [updated])
  }

  @Test
  func appendsToolResultAndRegistersMessageOnTurn() {
    let turnID = UUID()
    let result = ToolResultModelMessage(
      callID: UUID(),
      toolName: .listFiles,
      payload: .listFiles(
        ListFilesResult(
          root: WorkspaceRelativePath(rawValue: "."),
          entries: [
            WorkspaceFileEntry(path: WorkspaceRelativePath(rawValue: "README.md"), kind: .file)
          ]
        ))
    )
    var state = makeState(turns: [ChatTurn(id: turnID, status: .running)])

    ChatWorkflowEventApplier().apply(
      [.toolResultAppended(result, turnID: turnID)],
      to: &state
    )

    let items = state.transcriptItemsForTesting
    #expect(items.compactMap(\.messageID) == [result.callID])
    #expect(items[0].toolResultForTesting(records: state.toolCalls) == result)
    #expect(state.turns[0].items == [.tool(state.toolCalls[0])])
    #expect(state.turnID(containingToolCall: result.callID) == turnID)
    let projection = ChatModelContextBuilder().transcript(from: state)
    #expect(projection.entries.last?.sourceMessageID == result.callID)
  }

  @Test
  func appendsAssistantPlaceholderAndRegistersMessageOnTurn() {
    let turnID = UUID()
    let messageID = UUID()
    var state = makeState(turns: [ChatTurn(id: turnID, status: .running)])

    ChatWorkflowEventApplier().apply(
      [.assistantPlaceholderAppended(messageID: messageID, turnID: turnID)],
      to: &state
    )

    let items = state.transcriptItemsForTesting
    #expect(items.compactMap(\.messageID) == [messageID])
    #expect(items[0].kindForTesting == .assistant)
    #expect(items[0].deliveryStatusForTesting == .streaming)
    #expect(state.turns[0].items == items)
  }

  @Test
  func appendsTurnUserMessagePromptContextAndStreamingAssistantUpdates() throws {
    let turnID = UUID()
    let userMessageID = UUID()
    let assistantMessageID = UUID()
    let metrics = ChatGenerationMetrics(
      generatedTokenCount: 2,
      tokensPerSecond: 20
    )
    var state = makeState()

    ChatWorkflowEventApplier().apply(
      [
        .turnAppended(ChatTurn(id: turnID, status: .running)),
        .userMessageAppended(
          content: "say hello",
          messageID: userMessageID,
          turnID: turnID,
          attachments: [],
          promptContext: .empty(.focusedFileDefault)
        ),
        .assistantPlaceholderAppended(messageID: assistantMessageID, turnID: turnID),
        .assistantChunkAppended(chunk: "hello", messageID: assistantMessageID),
        .assistantGenerationCompleted(messageID: assistantMessageID, metrics: metrics),
      ],
      to: &state
    )

    let items = state.transcriptItemsForTesting
    #expect(state.turns.map(\.id) == [turnID])
    #expect(items.map(\.messageID) == [userMessageID, assistantMessageID])
    #expect(items[0].contentForTesting == "say hello")
    #expect(items[1].contentForTesting == "hello")
    #expect(items[1].deliveryStatusForTesting == .complete)
    #expect(items[1].generationMetricsForTesting == metrics)
    let projection = ChatModelContextBuilder().transcript(from: state)
    #expect(projection.entries.map(\.sourceMessageID) == [userMessageID, assistantMessageID])
    #expect(projection.entries.map(\.frozenContent.role) == [.user, .assistant])
  }

  @Test
  func appendsStreamedAssistantThinkingOutsideModelContext() {
    let turnID = UUID()
    let thinkingID = UUID()
    let assistantID = UUID()
    var state = makeState(turns: [ChatTurn(id: turnID, status: .running)])

    ChatWorkflowEventApplier().apply(
      [
        .assistantThinkingPlaceholderAppended(messageID: thinkingID, turnID: turnID),
        .assistantThinkingChunkAppended(chunk: "Inspecting the prompt.", messageID: thinkingID),
        .assistantThinkingCompleted(messageID: thinkingID),
        .assistantPlaceholderAppended(messageID: assistantID, turnID: turnID),
        .assistantChunkAppended(chunk: "Visible answer.", messageID: assistantID),
        .assistantGenerationCompleted(messageID: assistantID, metrics: nil),
      ],
      to: &state
    )

    #expect(state.turns[0].items.map(\.messageID) == [thinkingID, assistantID])
    guard case .assistantThinking(let thinkingMessage) = state.turns[0].items[0] else {
      Issue.record("Expected assistant thinking item.")
      return
    }
    #expect(thinkingMessage.content == "Inspecting the prompt.")
    #expect(thinkingMessage.deliveryStatus == .complete)
    #expect(state.turns[0].items[1].contentForTesting == "Visible answer.")
    let projection = ChatModelContextBuilder().transcript(from: state)
    #expect(projection.entries.map(\.frozenContent.role) == [.assistant])
    #expect(projection.entries[0].frozenContent.content == "Visible answer.")
  }

  @Test
  func modelProjectionDoesNotAppendSyntheticUserPromptAfterToolResult() {
    let turnID = UUID()
    let record = makeToolCallRecord(status: .completed)
    let state = makeState(
      turns: [
        ChatTurn(
          id: turnID,
          status: .running,
          items: [
            .userMessage(UserTurnMessage(content: "read README.md")),
            .tool(record),
          ]
        )
      ])

    let projection = ChatModelContextBuilder().transcript(from: state)

    let userPrompts = projection.entries.compactMap { entry -> String? in
      guard case .userPrompt(let context) = entry.body else {
        return nil
      }
      return context.prompt
    }
    #expect(userPrompts == ["read README.md"])
  }

  @Test
  func appendsDirectAssistantMessage() {
    let turnID = UUID()
    let messageID = UUID()
    var state = makeState(turns: [ChatTurn(id: turnID, status: .running)])

    ChatWorkflowEventApplier().apply(
      [
        .assistantMessageAppended(
          content: "Here is `README.md`:\n\n    1: project notes",
          modelProjectionPolicy: .override(
            "Displayed show_file result for README.md directly to the user."
          ),
          messageID: messageID,
          turnID: turnID
        )
      ],
      to: &state
    )

    let items = state.transcriptItemsForTesting
    #expect(items.compactMap(\.messageID) == [messageID])
    #expect(items[0].kindForTesting == .assistant)
    #expect(items[0].contentForTesting.contains("1: project notes"))
    #expect(items[0].deliveryStatusForTesting == .complete)
    guard case .assistantMessage(let message) = items[0] else {
      Issue.record("Expected assistant message.")
      return
    }
    #expect(
      message.modelProjectionPolicy
        == .override("Displayed show_file result for README.md directly to the user."))
    #expect(state.turns[0].items == items)
    let projection = ChatModelContextBuilder().transcript(from: state)
    #expect(projection.entries.map(\.frozenContent.role) == [.assistant])
    #expect(
      projection.entries[0].frozenContent.content
        == "Displayed show_file result for README.md directly to the user.")
  }

  @Test
  func updatesTurnStatusAndModelContextPolicy() {
    let turnID = UUID()
    var state = makeState(turns: [ChatTurn(id: turnID, status: .running)])

    ChatWorkflowEventApplier().apply(
      [
        .turnStatusChanged(
          turnID: turnID,
          status: .failed,
          modelContextPolicy: .excluded
        )
      ],
      to: &state
    )

    #expect(state.turns[0].status == .failed)
    #expect(state.turns[0].modelContextPolicy == .excluded)
  }

  @Test
  func updatesFocusedFileState() {
    var state = makeState()
    let focusedFileState = FocusedFileState(
      activePath: WorkspaceRelativePath(rawValue: "README.md"),
      recentPaths: [
        FocusedPath(
          path: WorkspaceRelativePath(rawValue: "README.md"),
          source: .readFile,
          confidence: .active
        )
      ]
    )

    ChatWorkflowEventApplier().apply(
      .focusedFileStateChanged(focusedFileState),
      to: &state
    )

    #expect(state.focusedFileState == focusedFileState)
  }

  @Test
  func updatesTodoState() {
    let todoState = TodoState(items: [
      TodoItem(id: "inspect", content: "Inspect files", status: .completed),
      TodoItem(id: "verify", content: "Run tests", status: .inProgress),
    ])
    var state = makeState()

    ChatWorkflowEventApplier().apply(.todoStateChanged(todoState), to: &state)

    #expect(state.todoState == todoState)
  }

  @Test
  func appliesStreamingCancellationAndPlaceholderCleanup() {
    let turnID = UUID()
    let cancelledID = UUID()
    let removedID = UUID()
    let keptID = UUID()
    var state = makeState(
      turns: [
        ChatTurn(
          id: turnID,
          status: .running,
          items: [
            .assistantMessage(
              AssistantTurnMessage(
                id: cancelledID,
                content: "partial",
                deliveryStatus: .streaming
              )),
            .assistantMessage(
              AssistantTurnMessage(
                id: removedID,
                content: "",
                deliveryStatus: .streaming
              )),
            .assistantMessage(
              AssistantTurnMessage(
                id: keptID,
                content: "done",
                deliveryStatus: .complete
              )),
          ]
        )
      ]
    )

    ChatWorkflowEventApplier().apply(
      [
        .streamingAssistantMessagesCancelled(turnID: turnID),
        .transientAssistantPlaceholdersRemoved,
      ],
      to: &state
    )

    let items = state.transcriptItemsForTesting
    #expect(items.compactMap(\.messageID) == [cancelledID, removedID, keptID])
    #expect(items[0].deliveryStatusForTesting == .cancelled)
    #expect(items[1].deliveryStatusForTesting == .cancelled)
    #expect(state.turns[0].items.map(testMessageID) == [cancelledID, removedID, keptID])
  }

  @Test
  func reportsMissingMessageTargetWithoutCrashingProductionApply() {
    let missingMessageID = UUID()
    let toolCall = ToolCallModelMessage(
      callID: UUID(),
      toolName: .readFile,
      arguments: [ToolCallModelArgument(name: "path", value: "README.md")]
    )
    let event = ChatWorkflowEvent.assistantAnnotatedAsNativeToolCall(
      assistantMessageID: missingMessageID,
      toolCall: toolCall
    )
    var state = makeState()

    let diagnostics = ChatWorkflowEventApplier().apply(event, to: &state)

    #expect(state.transcriptItemsForTesting.isEmpty)
    #expect(diagnostics.count == 1)
    #expect(diagnostics[0].event == event)
    #expect(diagnostics[0].missingTargetKind == .message)
    #expect(diagnostics[0].missingTargetID == missingMessageID)
  }

  @Test
  func reportsMissingTurnTargetWhileStillAppendingAuditableToolResult() {
    let missingTurnID = UUID()
    let result = ToolResultModelMessage(
      callID: UUID(),
      toolName: .listFiles,
      payload: .listFiles(
        ListFilesResult(
          root: WorkspaceRelativePath(rawValue: "."),
          entries: [
            WorkspaceFileEntry(path: WorkspaceRelativePath(rawValue: "README.md"), kind: .file)
          ]
        ))
    )
    let event = ChatWorkflowEvent.toolResultAppended(
      result,
      turnID: missingTurnID
    )
    var state = makeState()

    let diagnostics = ChatWorkflowEventApplier().apply(event, to: &state)

    let items = state.transcriptItemsForTesting
    #expect(items.compactMap(\.messageID) == [result.callID])
    #expect(items[0].toolResultForTesting(records: state.toolCalls) == result)
    #expect(diagnostics.count == 1)
    #expect(diagnostics[0].event == event)
    #expect(diagnostics[0].missingTargetKind == .turn)
    #expect(diagnostics[0].missingTargetID == missingTurnID)
  }

  @Test
  func reportsMissingToolCallUpdateTarget() {
    let record = makeToolCallRecord(status: .completed)
    let event = ChatWorkflowEvent.toolCallUpdated(record)
    var state = makeState()

    let diagnostics = ChatWorkflowEventApplier().apply(event, to: &state)

    #expect(state.toolCalls.isEmpty)
    #expect(diagnostics.count == 1)
    #expect(diagnostics[0].event == event)
    #expect(diagnostics[0].missingTargetKind == .toolCall)
    #expect(diagnostics[0].missingTargetID == record.id)
  }
}

private func makeState(
  items: [ChatTurnItem] = [],
  turns: [ChatTurn] = [],
  attachments: [ChatAttachment] = [],
  systemPrompt: String = "System",
  generationSettings: ChatGenerationSettings = .agentDefault
) -> ChatSession {
  let resolvedTurns =
    turns.isEmpty && !items.isEmpty
    ? [ChatTurn(status: .running, items: items)]
    : turns
  return ChatSession(
    turns: resolvedTurns,
    pendingAttachments: attachments,
    modeSettings: testModeSettings(
      systemPrompt: systemPrompt,
      generationSettings: generationSettings
    )
  )
}

private func makeToolCallRecord(
  request: ToolCallRequest? = nil,
  status: ToolCallStatus
) -> ToolCallRecord {
  let resolvedRequest =
    request
    ?? ToolCallRequest.validated(
      raw: RawToolCallRequest(
        workspaceID: UUID(),
        sessionID: UUID(),
        toolName: .listFiles
      ),
      payload: .listFiles(ListFilesInput(path: nil))
    )
  return ToolCallRecord(
    request: resolvedRequest,
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
