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
    var state = makeState(messages: [
      ChatMessage(id: assistantID, assistantContent: "<action>")
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

    #expect(state.messages[0].kind == .toolCall)
    #expect(state.messages[0].toolCall == toolCall)
  }

  @Test
  func appendsToolCallAndRegistersItOnTurn() {
    let turnID = UUID()
    let record = makeToolCallRecord(status: .completed)
    var state = makeState(turns: [ChatTurnRecord(id: turnID, status: .running)])

    ChatWorkflowEventApplier().apply(
      [.toolCallAppended(record, turnID: turnID)],
      to: &state
    )

    #expect(state.toolCalls == [record])
    #expect(state.turns[0].toolCallIDs == [record.id])
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
    let messageID = UUID()
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
    var state = makeState(turns: [ChatTurnRecord(id: turnID, status: .running)])

    ChatWorkflowEventApplier().apply(
      [.toolResultAppended(result, messageID: messageID, turnID: turnID)],
      to: &state
    )

    #expect(state.messages.map(\.id) == [messageID])
    #expect(state.messages[0].toolResult == result)
    #expect(state.turns[0].messageIDs == [messageID])
  }

  @Test
  func appendsAssistantPlaceholderAndRegistersMessageOnTurn() {
    let turnID = UUID()
    let messageID = UUID()
    var state = makeState(turns: [ChatTurnRecord(id: turnID, status: .running)])

    ChatWorkflowEventApplier().apply(
      [.assistantPlaceholderAppended(messageID: messageID, turnID: turnID)],
      to: &state
    )

    #expect(state.messages.map(\.id) == [messageID])
    #expect(state.messages[0].kind == .assistant)
    #expect(state.messages[0].deliveryStatus == .streaming)
    #expect(state.turns[0].messageIDs == [messageID])
  }

  @Test
  func appendsDirectAssistantMessageAndModelContextSummary() {
    let turnID = UUID()
    let messageID = UUID()
    var state = makeState(turns: [ChatTurnRecord(id: turnID, status: .running)])

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

    #expect(state.messages.map(\.id) == [messageID])
    #expect(state.messages[0].kind == .assistant)
    #expect(state.messages[0].content.contains("1: project notes"))
    #expect(state.messages[0].deliveryStatus == .complete)
    #expect(state.turns[0].messageIDs == [messageID])
    #expect(state.modelFacingTranscript.entries.map(\.frozenContent.role) == [.assistant])
    #expect(
      state.modelFacingTranscript.entries[0].frozenContent.content
        == "Displayed show_file result for README.md directly to the user.")
  }

  @Test
  func updatesTurnStatusAndModelContextPolicy() {
    let turnID = UUID()
    var state = makeState(turns: [ChatTurnRecord(id: turnID, status: .running)])

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
      messages: [
        ChatMessage(
          id: cancelledID,
          assistantContent: "partial",
          deliveryStatus: .streaming,
          turnID: turnID
        ),
        ChatMessage(
          id: removedID,
          assistantContent: "",
          deliveryStatus: .streaming,
          turnID: turnID
        ),
        ChatMessage(
          id: keptID,
          assistantContent: "done",
          deliveryStatus: .complete,
          turnID: turnID
        ),
      ],
      turns: [
        ChatTurnRecord(
          id: turnID,
          status: .running,
          messageIDs: [cancelledID, removedID, keptID]
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

    #expect(state.messages.map(\.id) == [cancelledID, keptID])
    #expect(state.messages[0].deliveryStatus == .cancelled)
    #expect(state.turns[0].messageIDs == [cancelledID, keptID])
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

    #expect(state.messages.isEmpty)
    #expect(diagnostics.count == 1)
    #expect(diagnostics[0].event == event)
    #expect(diagnostics[0].missingTargetKind == .message)
    #expect(diagnostics[0].missingTargetID == missingMessageID)
  }

  @Test
  func reportsMissingTurnTargetWhileStillAppendingAuditableToolResult() {
    let missingTurnID = UUID()
    let messageID = UUID()
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
      messageID: messageID,
      turnID: missingTurnID
    )
    var state = makeState()

    let diagnostics = ChatWorkflowEventApplier().apply(event, to: &state)

    #expect(state.messages.map(\.id) == [messageID])
    #expect(state.messages[0].toolResult == result)
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
  messages: [ChatMessage] = [],
  toolCalls: [ToolCallRecord] = [],
  turns: [ChatTurnRecord] = [],
  attachments: [ChatAttachment] = [],
  systemPrompt: String = "System",
  generationSettings: ChatGenerationSettings = .codingDefault
) -> ChatSessionState {
  ChatSessionState(
    messages: messages,
    toolCalls: toolCalls,
    turns: turns,
    attachments: attachments,
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
