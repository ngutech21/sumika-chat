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
      preview: ToolResultPreview(status: .success, text: "README.md")
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
    status: status,
    evaluation: ToolPermissionEvaluation(
      decision: .allowed,
      reason: "Allowed for test.",
      riskLevel: .low
    )
  )
}
