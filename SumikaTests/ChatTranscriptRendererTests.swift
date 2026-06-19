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
        "\(turnID.uuidString):assistant:\(assistantID.uuidString)",
        "\(turnID.uuidString):tool:\(toolID.uuidString)",
        "\(turnID.uuidString):assistant:\(placeholderID.uuidString)",
      ])
    #expect(parser.parsedContents == ["Answer", ""])
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
  func streamingAssistantUpdateReparsesOnlyThatAssistantMessage() {
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

    let items = renderer.items(for: [
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

    #expect(parser.parsedContents == ["Stable", "Stream", "Streaming"])
    #expect(items[0].assistantRenderBlocks == [parsedBlock(for: "Stable")])
    #expect(items[1].assistantRenderBlocks == [parsedBlock(for: "Streaming")])
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

    _ = renderer.items(for: [
      ChatTurn(
        id: turnID,
        status: .running,
        items: [
          .assistantMessage(AssistantTurnMessage(id: assistantID, content: "Done")),
          .tool(makeToolCallRecord(id: toolID, status: .running)),
        ]
      )
    ])

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
    #expect(items[1].toolCallRecord?.status == .completed)
    #expect(items[1].generationMetrics == metrics)
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
    #expect(parser.parsedContents == [""])
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

private func makeToolCallRecord(
  id: UUID,
  status: ToolCallStatus
) -> ToolCallRecord {
  let request = ToolCallRequest.validated(
    raw: RawToolCallRequest(
      id: id,
      workspaceID: UUID(),
      sessionID: UUID(),
      toolName: .browserRefresh
    ),
    payload: .browserRefresh(BrowserRefreshInput())
  )
  return ToolCallRecord(
    request: request,
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
      .browserRefresh(.success(path: nil, url: nil, hard: false)))
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
