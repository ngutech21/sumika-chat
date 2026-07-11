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
  func completedSuccessfulFinishTaskIsHiddenAndAssistantSummaryRemainsVisible() {
    let turnID = UUID()
    let userID = UUID()
    let ordinaryToolID = UUID()
    let finishID = UUID()
    let summaryID = UUID()
    let parser = AssistantBlockParserSpy()
    let renderer = ChatTranscriptRenderer(assistantBlocks: parser.blocks)

    let items = renderer.items(for: [
      ChatTurn(
        id: turnID,
        status: .completed,
        items: [
          .userMessage(UserTurnMessage(id: userID, content: "Finish the task")),
          .tool(makeToolCallRecord(id: ordinaryToolID, status: .completed)),
          .tool(makeFinishTaskRecord(id: finishID, state: .completed)),
          .assistantMessage(
            AssistantTurnMessage(id: summaryID, content: "Implemented and verified.")
          ),
        ]
      )
    ])

    #expect(
      items.map(\.id) == [
        "\(turnID.uuidString):user:\(userID.uuidString)",
        "\(turnID.uuidString):tool:\(ordinaryToolID.uuidString)",
        "\(turnID.uuidString):assistant:\(summaryID.uuidString)",
      ])
    #expect(parser.parsedContents == ["Implemented and verified."])
  }

  @Test
  func invalidAndFailedFinishTaskCallsRemainVisible() {
    let turnID = UUID()
    let invalidID = UUID()
    let failedID = UUID()
    let renderer = ChatTranscriptRenderer()

    let items = renderer.items(for: [
      ChatTurn(
        id: turnID,
        status: .failed,
        items: [
          .tool(makeInvalidFinishTaskRecord(id: invalidID)),
          .tool(makeFinishTaskRecord(id: failedID, state: .failed)),
        ]
      )
    ])

    #expect(
      items.map(\.id) == [
        "\(turnID.uuidString):tool:\(invalidID.uuidString)",
        "\(turnID.uuidString):tool:\(failedID.uuidString)",
      ])
    #expect(items.map { $0.toolCallRecord?.status } == [.failed, .failed])
  }

  @Test
  func runningFinishTaskBecomesHiddenWithoutLosingItsOrderingBoundary() {
    let turnID = UUID()
    let firstAssistantID = UUID()
    let finishID = UUID()
    let thinkingID = UUID()
    let summaryID = UUID()
    let renderer = ChatTranscriptRenderer()

    let runningItems = renderer.items(for: [
      ChatTurn(
        id: turnID,
        status: .running,
        items: [
          .assistantMessage(
            AssistantTurnMessage(id: firstAssistantID, content: "Preparing the result.")
          ),
          .tool(makeFinishTaskRecord(id: finishID, state: .running)),
        ]
      )
    ])
    #expect(
      runningItems.map(\.id) == [
        "\(turnID.uuidString):assistant:\(firstAssistantID.uuidString)",
        "\(turnID.uuidString):tool:\(finishID.uuidString)",
      ])

    let completedItems = renderer.items(for: [
      ChatTurn(
        id: turnID,
        status: .completed,
        items: [
          .assistantMessage(
            AssistantTurnMessage(id: firstAssistantID, content: "Preparing the result.")
          ),
          .tool(makeFinishTaskRecord(id: finishID, state: .completed)),
          .assistantThinking(
            AssistantThinkingMessage(id: thinkingID, content: "Finalizing the summary.")
          ),
          .assistantMessage(
            AssistantTurnMessage(id: summaryID, content: "Implemented and verified.")
          ),
        ]
      )
    ])

    #expect(
      completedItems.map(\.id) == [
        "\(turnID.uuidString):assistant:\(firstAssistantID.uuidString)",
        "\(turnID.uuidString):thinking:\(thinkingID.uuidString)",
        "\(turnID.uuidString):assistant:\(summaryID.uuidString)",
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
  func streamingAssistantParsesRawBlocksWithoutFinalBlockParser() {
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

    // The injected (preprocessing) parser stays reserved for final messages;
    // streaming content is parsed raw so appends cannot flip its rendering.
    #expect(parser.parsedContents == ["Stable"])
    #expect(streamingItems[0].assistantRenderBlocks == [parsedBlock(for: "Stable")])
    #expect(
      streamingItems[1].assistantRenderBlocks
        == AssistantRenderBlockParser().parse("Streaming"))

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
  func streamingAssistantBlocksGrowIncrementallyWithStableIdentity() {
    let turnID = UUID()
    let assistantID = UUID()
    let renderer = ChatTranscriptRenderer()

    func streamingTurn(_ content: String) -> ChatTurn {
      ChatTurn(
        id: turnID,
        status: .running,
        items: [
          .assistantMessage(
            AssistantTurnMessage(id: assistantID, content: content, deliveryStatus: .streaming)
          )
        ]
      )
    }

    let contentSteps = [
      "Intro paragraph.",
      "Intro paragraph.\n\n```swift\nlet value = 1",
      "Intro paragraph.\n\n```swift\nlet value = 1\nlet other = 2\n```\n",
      "Intro paragraph.\n\n```swift\nlet value = 1\nlet other = 2\n```\nOutro begins",
    ]

    for content in contentSteps {
      let items = renderer.items(for: [streamingTurn(content)])
      // The incremental tail reparse must be indistinguishable from a full
      // parse of the same content, including stable ordinal block IDs.
      #expect(items[0].assistantRenderBlocks == AssistantRenderBlockParser().parse(content))
    }

    let finalItems = renderer.items(for: [streamingTurn(contentSteps[3])])
    let codeBlocks = finalItems[0].assistantRenderBlocks.compactMap { block in
      if case .codeBlock(let codeBlock) = block {
        return codeBlock
      }
      return nil
    }
    #expect(codeBlocks.count == 1)
    #expect(codeBlocks.first?.isClosed == true)
    #expect(codeBlocks.first?.language == "swift")
  }

  @Test
  func streamingAssistantRegenerationReparsesFromScratch() {
    let turnID = UUID()
    let assistantID = UUID()
    let renderer = ChatTranscriptRenderer()

    func streamingTurn(_ content: String) -> ChatTurn {
      ChatTurn(
        id: turnID,
        status: .running,
        items: [
          .assistantMessage(
            AssistantTurnMessage(id: assistantID, content: content, deliveryStatus: .streaming)
          )
        ]
      )
    }

    _ = renderer.items(for: [streamingTurn("First answer draft.")])
    let regenerated = renderer.items(for: [streamingTurn("Rewritten.")])

    #expect(
      regenerated[0].assistantRenderBlocks == AssistantRenderBlockParser().parse("Rewritten."))
  }

  @Test
  func streamingReasoningHidesEmptyAssistantPlaceholderInSameTurn() {
    let turnID = UUID()
    let thinkingID = UUID()
    let assistantID = UUID()
    let renderer = ChatTranscriptRenderer()

    let items = renderer.items(for: [
      ChatTurn(
        id: turnID,
        status: .running,
        items: [
          .assistantThinking(
            AssistantThinkingMessage(
              id: thinkingID,
              content: "Inspecting files",
              deliveryStatus: .streaming
            )
          ),
          .assistantMessage(
            AssistantTurnMessage(
              id: assistantID,
              content: "",
              deliveryStatus: .streaming
            )
          ),
        ]
      )
    ])

    #expect(
      items.map(\.id) == [
        "\(turnID.uuidString):thinking:\(thinkingID.uuidString)"
      ])
  }

  @Test
  func streamingReasoningKeepsAssistantRowWithVisibleContent() {
    let turnID = UUID()
    let thinkingID = UUID()
    let assistantID = UUID()
    let renderer = ChatTranscriptRenderer()

    let items = renderer.items(for: [
      ChatTurn(
        id: turnID,
        status: .running,
        items: [
          .assistantThinking(
            AssistantThinkingMessage(
              id: thinkingID,
              content: "Inspecting files",
              deliveryStatus: .streaming
            )
          ),
          .assistantMessage(
            AssistantTurnMessage(
              id: assistantID,
              content: "Partial answer",
              deliveryStatus: .streaming
            )
          ),
        ]
      )
    ])

    #expect(
      items.map(\.id) == [
        "\(turnID.uuidString):thinking:\(thinkingID.uuidString)",
        "\(turnID.uuidString):assistant:\(assistantID.uuidString)",
      ])
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
  func multiApprovalPresentationUsesCanonicalBatchAnchorAndFirstOpenRecord() throws {
    let anchorID = UUID()
    let firstPendingID = UUID()
    let secondPendingID = UUID()
    let turn = ChatTurn(
      status: .awaitingApproval,
      items: [
        .tool(makeToolCallRecord(id: anchorID, status: .completed)),
        .assistantThinking(AssistantThinkingMessage(content: "Checking both changes.")),
        .tool(makeToolCallRecord(id: firstPendingID, status: .awaitingApproval)),
        .tool(makeToolCallRecord(id: secondPendingID, status: .awaitingApproval)),
      ]
    )

    let renderedTools = ChatTranscriptRenderer().items(for: [turn]).compactMap {
      item -> RenderedChatTurnItem? in
      guard case .tool = item.item else {
        return nil
      }
      return item
    }

    #expect(renderedTools.count == 3)
    #expect(renderedTools.allSatisfy { $0.toolBatchPresentation?.anchorID == anchorID })
    #expect(renderedTools.allSatisfy { $0.toolBatchPresentation?.pendingApprovalCount == 2 })
    #expect(renderedTools[0].toolBatchPresentation?.showsApproveAll == false)
    #expect(renderedTools[1].toolBatchPresentation?.showsApproveAll == true)
    #expect(renderedTools[2].toolBatchPresentation?.showsApproveAll == false)

    let decodedTurn = try JSONDecoder().decode(
      ChatTurn.self,
      from: JSONEncoder().encode(turn)
    )
    let decodedPresentations = ToolApprovalBatchPresentation.presentations(
      for: decodedTurn
    )
    #expect(decodedPresentations[firstPendingID]?.anchorID == anchorID)
    #expect(decodedPresentations[firstPendingID]?.showsApproveAll == true)
  }

  @Test
  func hiddenAssistantMessageStillSeparatesCanonicalApprovalBatches() {
    let firstID = UUID()
    let secondID = UUID()
    let items = ChatTranscriptRenderer().items(for: [
      ChatTurn(
        status: .awaitingApproval,
        items: [
          .tool(makeToolCallRecord(id: firstID, status: .awaitingApproval)),
          .assistantMessage(
            AssistantTurnMessage(content: "", deliveryStatus: .cancelled)
          ),
          .tool(makeToolCallRecord(id: secondID, status: .awaitingApproval)),
        ]
      )
    ])

    let renderedTools = items.filter { item in
      if case .tool = item.item {
        return true
      }
      return false
    }
    #expect(renderedTools.count == 2)
    #expect(renderedTools.allSatisfy { $0.toolBatchPresentation == nil })
  }

  @Test
  func siblingResolutionInvalidatesCachedApproveAllPresentation() {
    let firstID = UUID()
    let secondID = UUID()
    let renderer = ChatTranscriptRenderer()
    let awaitingTurn = ChatTurn(
      status: .awaitingApproval,
      items: [
        .tool(makeToolCallRecord(id: firstID, status: .awaitingApproval)),
        .tool(makeToolCallRecord(id: secondID, status: .awaitingApproval)),
      ]
    )
    let firstRender = renderer.items(for: [awaitingTurn])
    let initialFirstItem = firstRender[0]
    #expect(initialFirstItem.toolBatchPresentation?.showsApproveAll == true)

    let partiallyResolvedTurn = ChatTurn(
      id: awaitingTurn.id,
      status: .awaitingApproval,
      items: [
        .tool(makeToolCallRecord(id: firstID, status: .awaitingApproval)),
        .tool(makeToolCallRecord(id: secondID, status: .completed)),
      ]
    )
    let updatedFirstItem = renderer.items(for: [partiallyResolvedTurn])[0]

    #expect(updatedFirstItem.toolBatchPresentation == nil)
    #expect(updatedFirstItem.renderRevision != initialFirstItem.renderRevision)
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
  func generationIndicatorIsHiddenWhenReasoningIsStreaming() {
    let reasoningItem = renderedThinkingItem(
      AssistantThinkingMessage(content: "Inspecting files", deliveryStatus: .streaming)
    )

    #expect(
      ChatTranscriptGenerationIndicatorPolicy.shouldShow(
        isGenerating: true,
        items: [reasoningItem]
      ) == false)
  }

  @Test
  func generationIndicatorIsHiddenWhenAssistantMessageIsStreaming() {
    let assistantItem = renderedAssistantItem(
      AssistantTurnMessage(content: "Streaming", deliveryStatus: .streaming),
      blocks: []
    )

    #expect(
      ChatTranscriptGenerationIndicatorPolicy.shouldShow(
        isGenerating: true,
        items: [assistantItem]
      ) == false)
  }

  @Test
  func generationIndicatorShowsWhenGenerationHasNoActiveTranscriptRow() {
    let stableItem = renderedAssistantItem(
      AssistantTurnMessage(content: "Done", deliveryStatus: .complete),
      blocks: [parsedBlock(for: "Done")]
    )

    #expect(
      ChatTranscriptGenerationIndicatorPolicy.shouldShow(
        isGenerating: true,
        items: [stableItem]
      ))
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

private func renderedThinkingItem(_ message: AssistantThinkingMessage) -> RenderedChatTurnItem {
  RenderedChatTurnItem(
    id: "turn:thinking:\(message.id.uuidString)",
    item: .assistantThinking(message),
    toolCallRecord: nil,
    generationMetrics: nil,
    assistantRenderBlocks: []
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

private enum FinishTaskTestState {
  case running
  case completed
  case failed
}

private func makeFinishTaskRecord(
  id: UUID,
  state: FinishTaskTestState
) -> ToolCallRecord {
  let request = ToolCallRequest.validated(
    raw: RawToolCallRequest(
      id: id,
      workspaceID: UUID(),
      sessionID: UUID(),
      toolName: .finishTask,
      arguments: [
        "status": .string("done"),
        "summary": .string("Implemented and verified."),
      ]
    ),
    payload: .finishTask(
      FinishTaskInput(status: .done, summary: "Implemented and verified.")
    )
  )
  let toolState: ToolCallState =
    switch state {
    case .running:
      .running
    case .completed:
      .completed(.finishTask(.success))
    case .failed:
      .failed(
        .finishTask(.failed(reason: .executionError("Finish failed.")))
      )
    }
  return ToolCallRecord(
    request: request,
    evaluation: ToolPermissionEvaluation(
      decision: .allowed,
      reason: "Allowed for test.",
      riskLevel: .low
    ),
    state: toolState
  )
}

private func makeInvalidFinishTaskRecord(id: UUID) -> ToolCallRecord {
  let reason = InvalidToolCallReason.invalidArgumentType(
    name: "status",
    expected: "done, blocked, or needs_user"
  )
  let rawArguments: ToolCallArguments = [
    "status": .string("finished"),
    "summary": .string("Implemented and verified."),
  ]
  let request = ToolCallRequest.invalid(
    raw: RawToolCallRequest(
      id: id,
      workspaceID: UUID(),
      sessionID: UUID(),
      toolName: .finishTask,
      arguments: rawArguments
    ),
    input: InvalidToolInput(
      originalName: ToolName.finishTask.rawValue,
      rawArguments: rawArguments,
      reason: reason
    )
  )
  return ToolCallRecord(
    request: request,
    evaluation: ToolPermissionEvaluation(
      decision: .allowed,
      reason: "Allowed for test.",
      riskLevel: .low
    ),
    state: .failed(
      .invalidTool(
        InvalidToolResult(originalName: ToolName.finishTask.rawValue, reason: reason)
      )
    )
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
