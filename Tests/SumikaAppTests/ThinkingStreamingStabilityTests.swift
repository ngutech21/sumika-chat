import AppKit
import SumikaCore
import Testing

@testable import SumikaApp

// Pins the viewport stability contract while a thinking row streams: expanded
// reasoning follows growth monotonically for pinned viewports, unpinned
// viewports do not move at all, and collapsed reasoning (the default ticker
// presentation) keeps the transcript height constant entirely.
@MainActor
struct ThinkingStreamingStabilityTests {

  @Test
  func pinnedViewportFollowsExpandedStreamingThinkingWithoutBouncing() throws {
    let coordinator = AppKitChatTranscriptRepresentable.Coordinator(
      onToggleSpeech: { _, _ in },
      onApproveToolCall: { _ in },
      onDenyToolCall: { _ in },
      onAnswerAskUser: { _, _ in }
    )
    let scrollView = coordinator.makeScrollView()
    scrollView.setFrameSize(NSSize(width: 640, height: 300))
    let tableView = try #require(scrollView.documentView as? NSTableView)
    let viewportHeight = scrollView.contentView.bounds.height
    coordinator.toggleThinkingExpansion(rowID: "thinking")

    var thinkingContent = "Inspecting the workspace."
    var revision = 1

    func applyAndFlush() {
      coordinator.update(
        rows: [
          stabilityUserRow(id: "user", revision: 1),
          stabilityThinkingRow(id: "thinking", revision: revision, content: thinkingContent),
        ],
        accessibilityValue: "ready",
        isSpeechEnabled: false,
        activeSpeechRowID: nil,
        in: scrollView
      )
      coordinator.flushPendingHeightInvalidationForTesting()
      tableView.layoutSubtreeIfNeeded()
      coordinator.flushPendingStreamingHeightUpdateForTesting()
      tableView.layoutSubtreeIfNeeded()
    }

    applyAndFlush()

    let initialThinkingHeight = tableView.rect(ofRow: 1).height
    let userRowTop = tableView.rect(ofRow: 0).minY
    var previousClipY = scrollView.contentView.bounds.origin.y
    var previousDocumentHeight = tableView.bounds.height

    for _ in 1...24 {
      thinkingContent += " More reasoning arrives with additional evidence to weigh carefully."
      revision += 1
      applyAndFlush()

      let clipY = scrollView.contentView.bounds.origin.y
      let documentHeight = tableView.bounds.height
      let pinnedTargetY = max(documentHeight - viewportHeight, 0)

      #expect(documentHeight >= previousDocumentHeight)
      #expect(clipY >= previousClipY)
      #expect(abs(clipY - pinnedTargetY) <= 1)
      #expect(tableView.rect(ofRow: 0).minY == userRowTop)

      previousClipY = clipY
      previousDocumentHeight = documentHeight
    }

    #expect(tableView.rect(ofRow: 1).height > initialThinkingHeight)
    #expect(previousDocumentHeight > viewportHeight)
    #expect(previousClipY > 0)
  }

  @Test
  func unpinnedViewportStaysStillWhileExpandedThinkingGrows() throws {
    let coordinator = AppKitChatTranscriptRepresentable.Coordinator(
      onToggleSpeech: { _, _ in },
      onApproveToolCall: { _ in },
      onDenyToolCall: { _ in },
      onAnswerAskUser: { _, _ in }
    )
    let scrollView = coordinator.makeScrollView()
    scrollView.setFrameSize(NSSize(width: 640, height: 300))
    let tableView = try #require(scrollView.documentView as? NSTableView)
    coordinator.toggleThinkingExpansion(rowID: "thinking")

    var thinkingContent = String(
      repeating: "Reasoning already tall enough to scroll well past the viewport. ",
      count: 24
    )
    var revision = 1

    func applyAndFlush() {
      coordinator.update(
        rows: [
          stabilityUserRow(id: "user", revision: 1),
          stabilityThinkingRow(id: "thinking", revision: revision, content: thinkingContent),
        ],
        accessibilityValue: "ready",
        isSpeechEnabled: false,
        activeSpeechRowID: nil,
        in: scrollView
      )
      coordinator.flushPendingHeightInvalidationForTesting()
      tableView.layoutSubtreeIfNeeded()
      coordinator.flushPendingStreamingHeightUpdateForTesting()
      tableView.layoutSubtreeIfNeeded()
    }

    applyAndFlush()
    #expect(tableView.bounds.height > scrollView.contentView.bounds.height + 48)

    scrollView.contentView.scroll(to: .zero)
    scrollView.reflectScrolledClipView(scrollView.contentView)
    let userRowTop = tableView.rect(ofRow: 0).minY
    let initialThinkingHeight = tableView.rect(ofRow: 1).height

    for _ in 1...8 {
      thinkingContent += " More reasoning arrives while the reader stays scrolled up."
      revision += 1
      applyAndFlush()

      #expect(scrollView.contentView.bounds.origin.y == 0)
      #expect(tableView.rect(ofRow: 0).minY == userRowTop)
    }

    #expect(tableView.rect(ofRow: 1).height > initialThinkingHeight)
  }

  @Test
  func collapsedStreamingThinkingKeepsViewportAndRowHeightStill() throws {
    let coordinator = AppKitChatTranscriptRepresentable.Coordinator(
      onToggleSpeech: { _, _ in },
      onApproveToolCall: { _ in },
      onDenyToolCall: { _ in },
      onAnswerAskUser: { _, _ in }
    )
    let scrollView = coordinator.makeScrollView()
    scrollView.setFrameSize(NSSize(width: 640, height: 300))
    let tableView = try #require(scrollView.documentView as? NSTableView)

    var thinkingContent = "Inspecting the workspace."
    var revision = 1

    func applyAndFlush() {
      coordinator.update(
        rows: [
          stabilityUserRow(id: "user", revision: 1),
          stabilityThinkingRow(id: "thinking", revision: revision, content: thinkingContent),
        ],
        accessibilityValue: "ready",
        isSpeechEnabled: false,
        activeSpeechRowID: nil,
        in: scrollView
      )
      coordinator.flushPendingHeightInvalidationForTesting()
      tableView.layoutSubtreeIfNeeded()
      coordinator.flushPendingStreamingHeightUpdateForTesting()
      tableView.layoutSubtreeIfNeeded()
    }

    applyAndFlush()

    let initialThinkingHeight = tableView.rect(ofRow: 1).height
    let initialDocumentHeight = tableView.bounds.height
    let initialClipY = scrollView.contentView.bounds.origin.y

    for _ in 1...24 {
      thinkingContent += "\nMore reasoning arrives with additional evidence to weigh carefully."
      revision += 1
      applyAndFlush()

      #expect(tableView.rect(ofRow: 1).height == initialThinkingHeight)
      #expect(tableView.bounds.height == initialDocumentHeight)
      #expect(scrollView.contentView.bounds.origin.y == initialClipY)
    }
  }
}

private func stabilityUserRow(id: String, revision: Int) -> NativeTranscriptRow {
  NativeTranscriptRow(
    id: id,
    revision: revision,
    body: .item(
      RenderedChatTurnItem(
        id: id,
        item: .userMessage(UserTurnMessage(content: "Please explain the workspace.")),
        generationMetrics: nil,
        assistantRenderBlocks: [],
        renderRevision: revision
      ))
  )
}

private func stabilityThinkingRow(
  id: String,
  revision: Int,
  content: String
) -> NativeTranscriptRow {
  NativeTranscriptRow(
    id: id,
    revision: revision,
    body: .item(
      RenderedChatTurnItem(
        id: id,
        item: .assistantThinking(
          AssistantThinkingMessage(content: content, deliveryStatus: .streaming)
        ),
        generationMetrics: nil,
        assistantRenderBlocks: [],
        renderRevision: revision
      ))
  )
}
