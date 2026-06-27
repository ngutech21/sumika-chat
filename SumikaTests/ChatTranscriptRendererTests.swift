import Foundation
import SumikaCore
import Testing

@testable import Sumika

@MainActor
struct ChatTranscriptRendererTests {
  @Test
  func initialRenderKeepsTranscriptOrderAndParsesVisibleAssistantMessages() {
    let turnID = UUID()
    let userID = UUID()
    let thinkingID = UUID()
    let assistantID = UUID()
    let toolID = UUID()
    let placeholderID = UUID()
    let parser = AssistantBlockParserSpy()
    let renderer = ChatTranscriptRenderer(assistantBlocks: parser.blocks)

    let toolRecord = makeToolCallRecord(id: toolID, status: .running)
    let items = renderer.items(for: [
      ChatTurn(
        id: turnID,
        status: .running,
        items: [
          .userMessage(UserTurnMessage(id: userID, content: "Question")),
          .assistantThinking(
            AssistantThinkingMessage(id: thinkingID, content: "Working through it.")
          ),
          .assistantMessage(AssistantTurnMessage(id: assistantID, content: "Answer")),
          .tool(toolRecord),
          .assistantMessage(
            AssistantTurnMessage(id: placeholderID, content: "", deliveryStatus: .streaming)
          ),
        ]
      )
    ])

    #expect(
      items.map(\.id) == [
        "\(turnID.uuidString):user:\(userID.uuidString)",
        "\(turnID.uuidString):thinking:\(thinkingID.uuidString)",
        "\(turnID.uuidString):assistant:\(assistantID.uuidString)",
        "\(turnID.uuidString):tool:\(toolID.uuidString)",
        "\(turnID.uuidString):assistant:\(placeholderID.uuidString)",
      ])
    #expect(parser.parsedContents == ["Answer"])
  }

  @Test
  func lazyThinkingRendersBeforePrecreatedAssistantMessage() {
    let turnID = UUID()
    let userID = UUID()
    let assistantID = UUID()
    let thinkingID = UUID()
    let renderer = ChatTranscriptRenderer()

    let items = renderer.items(for: [
      ChatTurn(
        id: turnID,
        status: .completed,
        items: [
          .userMessage(UserTurnMessage(id: userID, content: "Question")),
          .assistantMessage(AssistantTurnMessage(id: assistantID, content: "Answer")),
          .assistantThinking(
            AssistantThinkingMessage(id: thinkingID, content: "Reasoning")
          ),
        ]
      )
    ])

    #expect(
      items.map(\.id) == [
        "\(turnID.uuidString):user:\(userID.uuidString)",
        "\(turnID.uuidString):thinking:\(thinkingID.uuidString)",
        "\(turnID.uuidString):assistant:\(assistantID.uuidString)",
      ])
  }

  @Test
  func toolFollowUpThinkingRendersBeforeFollowUpAssistantMessage() {
    let turnID = UUID()
    let userID = UUID()
    let firstThinkingID = UUID()
    let toolID = UUID()
    let assistantID = UUID()
    let followUpThinkingID = UUID()
    let renderer = ChatTranscriptRenderer()

    let items = renderer.items(for: [
      ChatTurn(
        id: turnID,
        status: .completed,
        items: [
          .userMessage(UserTurnMessage(id: userID, content: "Question")),
          .assistantThinking(
            AssistantThinkingMessage(id: firstThinkingID, content: "I should search.")
          ),
          .tool(makeToolCallRecord(id: toolID, status: .completed)),
          .assistantMessage(AssistantTurnMessage(id: assistantID, content: "Answer")),
          .assistantThinking(
            AssistantThinkingMessage(id: followUpThinkingID, content: "Now answer.")
          ),
        ]
      )
    ])

    #expect(
      items.map(\.id) == [
        "\(turnID.uuidString):user:\(userID.uuidString)",
        "\(turnID.uuidString):thinking:\(firstThinkingID.uuidString)",
        "\(turnID.uuidString):tool:\(toolID.uuidString)",
        "\(turnID.uuidString):thinking:\(followUpThinkingID.uuidString)",
        "\(turnID.uuidString):assistant:\(assistantID.uuidString)",
      ])
  }

  @Test
  func appendingTurnParsesOnlyNewAssistantMessage() {
    let firstTurnID = UUID()
    let secondTurnID = UUID()
    let firstAssistantID = UUID()
    let secondAssistantID = UUID()
    let parser = AssistantBlockParserSpy()
    let renderer = ChatTranscriptRenderer(assistantBlocks: parser.blocks)

    let firstTurn = ChatTurn(
      id: firstTurnID,
      status: .completed,
      items: [
        .assistantMessage(AssistantTurnMessage(id: firstAssistantID, content: "First"))
      ]
    )

    _ = renderer.items(for: [firstTurn])

    let secondTurn = ChatTurn(
      id: secondTurnID,
      status: .completed,
      items: [
        .assistantMessage(AssistantTurnMessage(id: secondAssistantID, content: "Second"))
      ]
    )
    let items = renderer.items(for: [firstTurn, secondTurn])

    #expect(parser.parsedContents == ["First", "Second"])
    #expect(
      items.map(\.id) == [
        "\(firstTurnID.uuidString):assistant:\(firstAssistantID.uuidString)",
        "\(secondTurnID.uuidString):assistant:\(secondAssistantID.uuidString)",
      ])
  }

  @Test
  func streamingAssistantUpdateSkipsBlockParsingUntilComplete() {
    let turnID = UUID()
    let stableAssistantID = UUID()
    let streamingAssistantID = UUID()
    let parser = AssistantBlockParserSpy()
    let renderer = ChatTranscriptRenderer(assistantBlocks: parser.blocks)

    _ = renderer.items(for: [
      ChatTurn(
        id: turnID,
        status: .running,
        items: [
          .assistantMessage(AssistantTurnMessage(id: stableAssistantID, content: "Stable")),
          .assistantMessage(
            AssistantTurnMessage(
              id: streamingAssistantID,
              content: "Stream",
              deliveryStatus: .streaming
            )
          ),
        ]
      )
    ])

    let streamingItems = renderer.items(for: [
      ChatTurn(
        id: turnID,
        status: .running,
        items: [
          .assistantMessage(AssistantTurnMessage(id: stableAssistantID, content: "Stable")),
          .assistantMessage(
            AssistantTurnMessage(
              id: streamingAssistantID,
              content: "Streaming",
              deliveryStatus: .streaming
            )
          ),
        ]
      )
    ])

    #expect(parser.parsedContents == ["Stable"])
    #expect(streamingItems[0].assistantRenderBlocks == [parsedBlock(for: "Stable")])
    #expect(streamingItems[1].assistantRenderBlocks.isEmpty)

    let completedItems = renderer.items(for: [
      ChatTurn(
        id: turnID,
        status: .completed,
        items: [
          .assistantMessage(AssistantTurnMessage(id: stableAssistantID, content: "Stable")),
          .assistantMessage(
            AssistantTurnMessage(
              id: streamingAssistantID,
              content: "Streaming",
              deliveryStatus: .complete
            )
          ),
        ]
      )
    ])

    #expect(parser.parsedContents == ["Stable", "Streaming"])
    #expect(completedItems[1].assistantRenderBlocks == [parsedBlock(for: "Streaming")])
  }

  @Test
  func metricsAndToolStatusUpdatesDoNotReparseUnchangedAssistantContent() {
    let turnID = UUID()
    let assistantID = UUID()
    let toolID = UUID()
    let metrics = ChatGenerationMetrics(
      generatedTokenCount: 12,
      tokensPerSecond: 3,
      durationMs: 4000
    )
    let parser = AssistantBlockParserSpy()
    let renderer = ChatTranscriptRenderer(assistantBlocks: parser.blocks)

    let initialItems = renderer.items(for: [
      ChatTurn(
        id: turnID,
        status: .running,
        items: [
          .assistantMessage(AssistantTurnMessage(id: assistantID, content: "Done")),
          .tool(makeToolCallRecord(id: toolID, status: .running)),
        ]
      )
    ])
    let initialAssistantRevision = initialItems[0].renderRevision
    let initialToolRevision = initialItems[1].renderRevision

    let items = renderer.items(for: [
      ChatTurn(
        id: turnID,
        status: .completed,
        items: [
          .assistantMessage(
            AssistantTurnMessage(
              id: assistantID,
              content: "Done",
              generationMetrics: metrics
            )
          ),
          .tool(makeToolCallRecord(id: toolID, status: .completed)),
        ]
      )
    ])

    #expect(parser.parsedContents == ["Done"])
    #expect(items.count == 2)
    #expect(items[0].generationMetrics == metrics)
    #expect(items[0].renderRevision != initialAssistantRevision)
    #expect(items[1].toolCallRecord?.status == .completed)
    #expect(items[1].generationMetrics == metrics)
    #expect(items[1].renderRevision != initialToolRevision)
  }

  @Test
  func assistantSpokenTextUsesOnlyCompletedParagraphBlocks() {
    let turnID = UUID()
    let assistantID = UUID()
    let renderer = ChatTranscriptRenderer { _ in
      [
        .paragraph(.init(id: .init(rawValue: "intro"), text: "Intro")),
        .codeBlock(
          .init(
            id: .init(rawValue: "code"),
            language: "swift",
            text: "let value = 1",
            isClosed: true
          )
        ),
        .paragraph(.init(id: .init(rawValue: "outro"), text: "Outro")),
      ]
    }

    let items = renderer.items(for: [
      ChatTurn(
        id: turnID,
        status: .completed,
        items: [
          .assistantMessage(AssistantTurnMessage(id: assistantID, content: "Mixed"))
        ]
      )
    ])

    #expect(items.first?.assistantSpokenText == "Intro\n\nOutro")
  }

  @Test
  func assistantSpokenTextIsNilForCodeOnlyAndStreamingMessages() {
    let turnID = UUID()
    let codeAssistantID = UUID()
    let streamingAssistantID = UUID()
    let renderer = ChatTranscriptRenderer { content in
      if content == "code" {
        return [
          .codeBlock(
            .init(
              id: .init(rawValue: "code"),
              language: "swift",
              text: "let value = 1",
              isClosed: true
            )
          )
        ]
      }
      return [.paragraph(.init(id: .init(rawValue: "text"), text: content))]
    }

    let items = renderer.items(for: [
      ChatTurn(
        id: turnID,
        status: .running,
        items: [
          .assistantMessage(AssistantTurnMessage(id: codeAssistantID, content: "code")),
          .assistantMessage(
            AssistantTurnMessage(
              id: streamingAssistantID,
              content: "Streaming text",
              deliveryStatus: .streaming
            )
          ),
        ]
      )
    ])

    #expect(items.map(\.assistantSpokenText) == [nil, nil])
  }

  @Test
  func toolHeaderPreviewAndResultChangesAffectRenderRevision() {
    let toolID = UUID()
    let approvalPreview = ToolResultPreview(text: "Reload preview A")
    let initialRecord = makeToolCallRecord(
      id: toolID,
      status: .awaitingApproval,
      hard: false,
      approvalPreview: approvalPreview
    )
    let headerChangedRecord = makeToolCallRecord(
      id: toolID,
      status: .awaitingApproval,
      hard: true,
      approvalPreview: approvalPreview
    )
    let previewChangedRecord = makeToolCallRecord(
      id: toolID,
      status: .awaitingApproval,
      hard: false,
      approvalPreview: ToolResultPreview(text: "Reload preview B")
    )
    let completedSoftRecord = makeToolCallRecord(id: toolID, status: .completed, hard: false)
    let completedHardRecord = makeToolCallRecord(id: toolID, status: .completed, hard: true)

    let initialItem = renderedToolItem(initialRecord)

    #expect(initialItem.renderRevision != renderedToolItem(headerChangedRecord).renderRevision)
    #expect(initialItem.renderRevision != renderedToolItem(previewChangedRecord).renderRevision)
    #expect(
      renderedToolItem(completedSoftRecord).renderRevision
        != renderedToolItem(completedHardRecord).renderRevision
    )
  }

  @Test
  func assistantBlockCodeChangesAffectRenderRevision() {
    let message = AssistantTurnMessage(id: UUID(), content: "```swift\nprint(1)")
    let openCodeItem = renderedAssistantItem(
      message,
      blocks: [
        .codeBlock(
          .init(
            id: .init(rawValue: "code"),
            language: "swift",
            text: "print(1)",
            isClosed: false
          ))
      ]
    )
    let closedCodeItem = renderedAssistantItem(
      message,
      blocks: [
        .codeBlock(
          .init(
            id: .init(rawValue: "code"),
            language: "swift",
            text: "print(1)",
            isClosed: true
          ))
      ]
    )
    let changedCodeItem = renderedAssistantItem(
      message,
      blocks: [
        .codeBlock(
          .init(
            id: .init(rawValue: "code"),
            language: "swift",
            text: "print(2)",
            isClosed: false
          ))
      ]
    )

    #expect(openCodeItem.renderRevision != closedCodeItem.renderRevision)
    #expect(openCodeItem.renderRevision != changedCodeItem.renderRevision)
  }

  @Test
  func attachmentIdentityAndDisplayChangesAffectMessageRevision() {
    let attachmentID = UUID()
    let userID = UUID()
    let assistantID = UUID()
    let firstAttachment = makeAttachment(id: attachmentID, displayName: "first.txt")
    let renamedAttachment = makeAttachment(id: attachmentID, displayName: "renamed.txt")
    let replacedAttachment = makeAttachment(id: UUID(), displayName: "first.txt")

    let firstUserItem = renderedUserItem(
      UserTurnMessage(id: userID, content: "Use this", attachments: [firstAttachment])
    )
    let renamedUserItem = renderedUserItem(
      UserTurnMessage(id: userID, content: "Use this", attachments: [renamedAttachment])
    )
    let replacedUserItem = renderedUserItem(
      UserTurnMessage(id: userID, content: "Use this", attachments: [replacedAttachment])
    )

    let firstAssistantItem = renderedAssistantItem(
      AssistantTurnMessage(id: assistantID, content: "Attached", attachments: [firstAttachment]),
      blocks: [parsedBlock(for: "Attached")]
    )
    let renamedAssistantItem = renderedAssistantItem(
      AssistantTurnMessage(id: assistantID, content: "Attached", attachments: [renamedAttachment]),
      blocks: [parsedBlock(for: "Attached")]
    )

    #expect(firstUserItem.renderRevision != renamedUserItem.renderRevision)
    #expect(firstUserItem.renderRevision != replacedUserItem.renderRevision)
    #expect(firstAssistantItem.renderRevision != renamedAssistantItem.renderRevision)
  }

  @Test
  func placeholderVisibilityMatchesAssistantDeliveryState() {
    let turnID = UUID()
    let visiblePlaceholderID = UUID()
    let hiddenCancelledID = UUID()
    let parser = AssistantBlockParserSpy()
    let renderer = ChatTranscriptRenderer(assistantBlocks: parser.blocks)

    let items = renderer.items(for: [
      ChatTurn(
        id: turnID,
        status: .cancelled,
        items: [
          .assistantMessage(
            AssistantTurnMessage(
              id: visiblePlaceholderID,
              content: "",
              deliveryStatus: .streaming
            )
          ),
          .assistantMessage(
            AssistantTurnMessage(
              id: hiddenCancelledID,
              content: "",
              deliveryStatus: .cancelled
            )
          ),
        ]
      )
    ])

    #expect(
      items.map(\.id) == [
        "\(turnID.uuidString):assistant:\(visiblePlaceholderID.uuidString)"
      ])
    #expect(items.first?.shouldShowAssistantPlaceholder == true)
    #expect(parser.parsedContents.isEmpty)
  }

  @Test
  func removedAssistantMessagesArePrunedFromBlockCache() {
    let turnID = UUID()
    let assistantID = UUID()
    let parser = AssistantBlockParserSpy()
    let renderer = ChatTranscriptRenderer(assistantBlocks: parser.blocks)

    let turn = ChatTurn(
      id: turnID,
      status: .completed,
      items: [
        .assistantMessage(AssistantTurnMessage(id: assistantID, content: "Reusable"))
      ]
    )

    _ = renderer.items(for: [turn])
    _ = renderer.items(for: [])
    let items = renderer.items(for: [turn])

    #expect(parser.parsedContents == ["Reusable", "Reusable"])
    #expect(items.first?.assistantRenderBlocks == [parsedBlock(for: "Reusable")])
  }
}

@MainActor
private final class AssistantBlockParserSpy {
  private(set) var parsedContents: [String] = []

  func blocks(for content: String) -> [AssistantRenderBlock] {
    parsedContents.append(content)
    return [parsedBlock(for: content)]
  }
}

private func parsedBlock(for content: String) -> AssistantRenderBlock {
  .paragraph(
    .init(
      id: .init(rawValue: "parsed-\(content)"),
      text: content
    ))
}

private func renderedUserItem(_ message: UserTurnMessage) -> RenderedChatTurnItem {
  RenderedChatTurnItem(
    id: "turn:user:\(message.id.uuidString)",
    item: .userMessage(message),
    toolCallRecord: nil,
    generationMetrics: nil,
    assistantRenderBlocks: []
  )
}

private func renderedAssistantItem(
  _ message: AssistantTurnMessage,
  blocks: [AssistantRenderBlock]
) -> RenderedChatTurnItem {
  RenderedChatTurnItem(
    id: "turn:assistant:\(message.id.uuidString)",
    item: .assistantMessage(message),
    toolCallRecord: nil,
    generationMetrics: message.generationMetrics,
    assistantRenderBlocks: blocks
  )
}

private func renderedToolItem(_ record: ToolCallRecord) -> RenderedChatTurnItem {
  RenderedChatTurnItem(
    id: "turn:tool:\(record.id.uuidString)",
    item: .tool(record),
    toolCallRecord: record,
    generationMetrics: nil,
    assistantRenderBlocks: []
  )
}

private func makeAttachment(
  id: UUID,
  displayName: String
) -> ChatAttachment {
  ChatAttachment(
    id: id,
    url: URL(fileURLWithPath: "/tmp/\(displayName)"),
    displayName: displayName,
    kind: .text,
    content: "Attachment body",
    metadata: ChatAttachmentMetadata(
      mimeType: nil,
      byteCount: 15,
      contentSHA256: "attachment-body"
    )
  )
}

private func makeToolCallRecord(
  id: UUID,
  status: ToolCallStatus,
  hard: Bool = false,
  approvalPreview: ToolResultPreview? = nil
) -> ToolCallRecord {
  let request = ToolCallRequest.validated(
    raw: RawToolCallRequest(
      id: id,
      workspaceID: UUID(),
      sessionID: UUID(),
      toolName: .browserRefresh,
      arguments: ["hard": .bool(hard)]
    ),
    payload: .browserRefresh(BrowserRefreshInput(hard: hard))
  )
  return ToolCallRecord(
    request: request,
    evaluation: ToolPermissionEvaluation(
      decision: .allowed,
      reason: "Allowed for test.",
      riskLevel: .low
    ),
    state: toolCallState(status: status, hard: hard, approvalPreview: approvalPreview)
  )
}

private func toolCallState(
  status: ToolCallStatus,
  hard: Bool,
  approvalPreview: ToolResultPreview?
) -> ToolCallState {
  switch status {
  case .pending:
    return .pending
  case .awaitingApproval:
    return .awaitingApproval(preview: approvalPreview)
  case .awaitingUserAnswer:
    return .awaitingUserAnswer
  case .running:
    return .running
  case .completed:
    return .completed(
      .browserRefresh(.success(path: nil, url: nil, hard: hard)))
  case .denied:
    return .denied(
      .failure(ToolFailure(toolName: .browserRefresh, path: nil, reason: .permissionDenied)))
  case .failed:
    return .failed(
      .failure(
        ToolFailure(toolName: .browserRefresh, path: nil, reason: .executionError("Failed."))))
  case .cancelled:
    return .cancelled
  }
}
