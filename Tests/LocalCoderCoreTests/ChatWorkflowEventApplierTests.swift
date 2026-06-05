import Foundation
import Testing

@testable import LocalCoderCore

struct ChatWorkflowEventApplierTests {
  @Test
  func annotatesAssistantMessageAsToolCall() {
    let assistantID = UUID()
    let toolCall = ToolCallModelMessage(
      callID: UUID(),
      toolName: .readFile,
      arguments: [ToolCallModelArgument(name: "path", value: "README.md")]
    )
    var state = makeState(items: [
      .assistantMessage(AssistantTurnMessage(id: assistantID, content: "<action>"))
    ])

    ChatWorkflowEventApplier().apply(
      [
        .assistantMessageAnnotatedAsToolCall(
          assistantMessageID: assistantID,
          toolCall: toolCall
        )
      ],
      to: &state
    )

    let items = state.transcriptItemsForTesting
    #expect(items[0].kindForTesting == .toolCall)
    #expect(items[0].toolCallForTesting(records: state.toolCalls) == toolCall)
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
    #expect(state.turns[0].items == [.toolCall(record.id)])
  }

  @Test
  func replacesExistingToolCallRecord() {
    var existing = makeToolCallRecord(status: .awaitingApproval)
    let updated = makeToolCallRecord(request: existing.request, status: .completed)
    existing.events.append(
      ToolCallEvent(actor: .assistant, kind: .requested, message: "Requested.")
    )
    var state = makeState(toolCalls: [existing])

    ChatWorkflowEventApplier().apply(
      [.toolCallReplaced(updated)],
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
    #expect(state.turns[0].items == [.toolResult(result.callID)])
    #expect(state.modelFacingTranscript.entries[0].sourceMessageID == result.callID)
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
  func appendsDirectAssistantMessageAndModelContextSummary() {
    let turnID = UUID()
    let messageID = UUID()
    var state = makeState(turns: [ChatTurn(id: turnID, status: .running)])

    ChatWorkflowEventApplier().apply(
      [
        .assistantMessageAppended(
          content: "Here is `README.md`:\n\n    1: project notes",
          modelContextContent: "Displayed show_file result for README.md directly to the user.",
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
    #expect(state.turns[0].items == items)
    #expect(state.modelFacingTranscript.entries.map(\.frozenContent.role) == [.assistant])
    #expect(
      state.modelFacingTranscript.entries[0].frozenContent.content
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
    #expect(items.compactMap(\.messageID) == [cancelledID, keptID])
    #expect(items[0].deliveryStatusForTesting == .cancelled)
    #expect(state.turns[0].items.map(testMessageID) == [cancelledID, keptID])
  }

  @Test
  func reportsMissingMessageTargetWithoutCrashingProductionApply() {
    let missingMessageID = UUID()
    let toolCall = ToolCallModelMessage(
      callID: UUID(),
      toolName: .readFile,
      arguments: [ToolCallModelArgument(name: "path", value: "README.md")]
    )
    let event = ChatWorkflowEvent.assistantMessageAnnotatedAsToolCall(
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
  func reportsMissingToolCallReplacementTarget() {
    let record = makeToolCallRecord(status: .completed)
    let event = ChatWorkflowEvent.toolCallReplaced(record)
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
  toolCalls: [ToolCallRecord] = [],
  turns: [ChatTurn] = [],
  attachments: [ChatAttachment] = [],
  systemPrompt: String = "System",
  generationSettings: ChatGenerationSettings = .codingDefault
) -> ChatSession {
  let resolvedTurns =
    turns.isEmpty && !items.isEmpty
    ? [ChatTurn(status: .running, items: items)]
    : turns
  return ChatSession(
    toolCalls: toolCalls,
    turns: resolvedTurns,
    pendingAttachments: attachments,
    systemPrompt: systemPrompt,
    generationSettings: generationSettings
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
  case .approved:
    return .approved
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
