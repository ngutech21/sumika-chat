import AppKit
import SumikaCore
import Testing

@testable import Sumika

@MainActor
struct AppKitChatTranscriptDiffPlanTests {
  @Test
  func sameRowIDsReconfigureChangedRowsWithoutSnapshot() {
    let plan = NativeTranscriptDiffPlan.make(
      previousIDs: ["user", "assistant"],
      previousRevisions: ["user": 1, "assistant": 1],
      currentIDs: ["user", "assistant"],
      currentRevisions: ["user": 1, "assistant": 2]
    )

    #expect(plan.action == .reconfigureRows)
    #expect(plan.changedIDs == ["assistant"])
  }

  @Test
  func appendedUserRowAppliesSnapshotAndScrollsWhenOutgoing() {
    let existingRow = nativeAssistantRow(id: "assistant", revision: 1)
    let appendedRow = nativeUserRow(id: "user", revision: 1)
    let currentRows = [existingRow, appendedRow]
    let plan = NativeTranscriptDiffPlan.make(
      previousIDs: [existingRow.id],
      previousRevisions: [existingRow.id: existingRow.revision],
      currentIDs: currentRows.map(\.id),
      currentRevisions: revisionMap(currentRows)
    )

    #expect(plan.action == .snapshot)
    #expect(plan.changedIDs == ["user"])
    #expect(
      NativeTranscriptScrollDecision.shouldScrollToBottomAfterAppend(
        previousIDs: [existingRow.id],
        currentRows: currentRows
      )
    )
  }

  @Test
  func appendedAssistantRowDoesNotForceOutgoingScrollDecision() {
    let existingRow = nativeUserRow(id: "user", revision: 1)
    let appendedRow = nativeAssistantRow(id: "assistant", revision: 1)

    #expect(
      NativeTranscriptScrollDecision.shouldScrollToBottomAfterAppend(
        previousIDs: [existingRow.id],
        currentRows: [existingRow, appendedRow]
      ) == false
    )
  }

  @Test
  func heightCacheKeysByRowRevisionAndWidth() {
    var cache = NativeTranscriptHeightCache()
    let row = NativeTranscriptRow(
      id: "generation",
      revision: 1,
      body: .generationIndicator(revision: 1)
    )

    _ = cache.height(for: row, width: 400)
    #expect(cache.cachedEntryCount == 1)

    _ = cache.height(for: row, width: 400.8)
    #expect(cache.cachedEntryCount == 1)

    _ = cache.height(for: row, width: 401)
    #expect(cache.cachedEntryCount == 2)

    let revisedRow = NativeTranscriptRow(
      id: "generation",
      revision: 2,
      body: .generationIndicator(revision: 2)
    )
    _ = cache.height(for: revisedRow, width: 400)
    #expect(cache.cachedEntryCount == 3)

    cache.invalidate(rowID: "generation")
    #expect(cache.cachedEntryCount == 0)
  }

  @Test
  func codeOnlyHighlightUpdateDoesNotChangeRowDiffOrHeightCache() {
    var cache = NativeTranscriptHeightCache()
    let row = nativeAssistantCodeRow(id: "assistant", revision: 1, code: "let value = 1")
    let plan = NativeTranscriptDiffPlan.make(
      previousIDs: [row.id],
      previousRevisions: [row.id: row.revision],
      currentIDs: [row.id],
      currentRevisions: [row.id: row.revision]
    )

    _ = cache.height(for: row, width: 640)
    _ = cache.height(for: row, width: 640)

    #expect(plan.action == .reconfigureRows)
    #expect(plan.changedIDs.isEmpty)
    #expect(cache.cachedEntryCount == 1)
  }

  @Test
  func codeContentChangesAffectHeightCacheRevision() {
    var cache = NativeTranscriptHeightCache()
    let row = nativeAssistantCodeRow(id: "assistant", revision: 1, code: "let value = 1")
    let revisedRow = nativeAssistantCodeRow(
      id: "assistant",
      revision: 2,
      code: "let value = 1\nlet other = 2"
    )

    _ = cache.height(for: row, width: 640)
    let revisedHeight = cache.height(for: revisedRow, width: 640)

    #expect(cache.cachedEntryCount == 2)
    #expect(revisedHeight > 0)
  }

  @Test
  func expandedToolRowsUseExpandedHeightCacheKey() {
    var cache = NativeTranscriptHeightCache()
    let row = nativeToolRow(id: "tool", revision: 1)

    let collapsedHeight = cache.height(for: row, width: 640)
    let expandedHeight = cache.height(
      for: row,
      width: 640,
      state: NativeTranscriptCellState(isToolExpanded: true)
    )

    #expect(expandedHeight > collapsedHeight)
    #expect(cache.cachedEntryCount == 2)
  }

  @Test
  func expandedToolRowsMeasureWrappingDetailLines() {
    let shortRow = nativeToolRow(
      id: "tool-short",
      revision: 1,
      record: nativeApprovalToolRecord(reason: "Needs permission.")
    )
    let longRow = nativeToolRow(
      id: "tool-long",
      revision: 1,
      record: nativeApprovalToolRecord(
        reason:
          "Needs permission because this command can modify multiple generated files and should remain inspectable before execution."
      )
    )

    let shortHeight = NativeTranscriptRowMeasurer.height(
      for: shortRow,
      width: 360,
      state: NativeTranscriptCellState(isToolExpanded: true)
    )
    let longHeight = NativeTranscriptRowMeasurer.height(
      for: longRow,
      width: 360,
      state: NativeTranscriptCellState(isToolExpanded: true)
    )

    #expect(longHeight > shortHeight)
  }

  @Test
  func imageAttachmentsUsePreviewHeightInUserRows() {
    let textRow = nativeUserRow(
      id: "user-text-attachment",
      revision: 1,
      attachments: [nativeTextAttachment(displayName: "notes.txt")]
    )
    let imageRow = nativeUserRow(
      id: "user-image-attachment",
      revision: 1,
      attachments: [nativeImageAttachment(displayName: "screen.png")]
    )

    let textHeight = NativeTranscriptRowMeasurer.height(for: textRow, width: 640)
    let imageHeight = NativeTranscriptRowMeasurer.height(for: imageRow, width: 640)

    #expect(imageHeight > textHeight + 80)
  }

  @Test
  func imageAttachmentsUsePreviewHeightInAssistantRows() {
    let row = nativeAssistantRow(
      id: "assistant-image-attachment",
      revision: 1,
      attachments: [nativeImageAttachment(displayName: "result.png")]
    )

    let height = NativeTranscriptRowMeasurer.height(for: row, width: 640)

    #expect(height > NativeTranscriptAttachmentPreviewMetrics.imageHeight)
  }

  @Test
  func attachmentThumbnailDescriptorTracksContentSignature() {
    let attachmentID = AttachmentID()
    let first = nativeImageAttachment(
      id: attachmentID,
      displayName: "screen.png",
      contentSHA256: "first"
    )
    let second = nativeImageAttachment(
      id: attachmentID,
      displayName: "screen.png",
      contentSHA256: "second"
    )

    let firstDescriptor = NativeAttachmentThumbDescriptor(
      attachment: first,
      maxPixelSize: 360
    )
    let secondDescriptor = NativeAttachmentThumbDescriptor(
      attachment: second,
      maxPixelSize: 360
    )

    #expect(firstDescriptor != secondDescriptor)
  }

  @Test
  func nativeToolDetailsIncludeApprovalPreviewAndPermissionReason() {
    let record = nativeApprovalToolRecord()
    let details = NativeToolDetailContent(record: record)

    #expect(details.argumentLines.contains("command: uv test"))
    #expect(details.permissionLines.contains("Risk: high"))
    #expect(details.permissionLines.contains("Reason: Needs permission."))
    #expect(details.outputTitle == "Preview")
    #expect(details.outputText == "Runs tests.")
    #expect(details.affectedPaths == ["Package.swift"])
    #expect(details.flags == ["truncated"])
    #expect(!details.isEmpty)
  }

  @Test
  func nativeToolDetailsProjectCompletedCommandOutput() {
    let record = nativeCompletedCommandToolRecord()
    let details = NativeToolDetailContent(record: record)

    #expect(details.argumentLines.contains("command: swift test"))
    #expect(details.outputTitle == "Result")
    #expect(details.outputText?.contains("Tests passed.") == true)
    #expect(details.affectedPaths == ["."])
    #expect(details.flags.isEmpty)
  }

  @Test
  func coordinatorStateIsStoredByRowIDAndPrunedByActiveRows() {
    var store = NativeTranscriptCoordinatorState()

    store.setCopied(true, rowID: "tool")
    store.toggleToolExpansion(rowID: "tool")
    store.updateAskUserSelection("Yes", rowID: "tool")

    #expect(
      store.state(for: "tool")
        == NativeTranscriptCellState(
          isCopied: true,
          isToolExpanded: true,
          askUserSelection: "Yes"
        )
    )
    #expect(
      store.state(for: "other")
        == NativeTranscriptCellState(
          isCopied: false,
          isToolExpanded: false,
          askUserSelection: nil
        )
    )

    store.prune(activeRowIDs: ["other"])

    #expect(
      store.state(for: "tool")
        == NativeTranscriptCellState(
          isCopied: false,
          isToolExpanded: false,
          askUserSelection: nil
        )
    )
  }
}

private func revisionMap(_ rows: [NativeTranscriptRow]) -> [String: Int] {
  Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.revision) })
}

private func nativeUserRow(
  id: String,
  revision: Int,
  attachments: [ChatAttachment] = []
) -> NativeTranscriptRow {
  NativeTranscriptRow(
    id: id,
    revision: revision,
    body: .item(
      RenderedChatTurnItem(
        id: id,
        item: .userMessage(UserTurnMessage(content: "Question", attachments: attachments)),
        toolCallRecord: nil,
        generationMetrics: nil,
        assistantRenderBlocks: []
      ))
  )
}

private func nativeAssistantRow(
  id: String,
  revision: Int,
  attachments: [ChatAttachment] = []
) -> NativeTranscriptRow {
  NativeTranscriptRow(
    id: id,
    revision: revision,
    body: .item(
      RenderedChatTurnItem(
        id: id,
        item: .assistantMessage(
          AssistantTurnMessage(content: "Answer", attachments: attachments)
        ),
        toolCallRecord: nil,
        generationMetrics: nil,
        assistantRenderBlocks: [
          .paragraph(.init(id: .init(rawValue: "answer"), text: "Answer"))
        ]
      ))
  )
}

private func nativeAssistantCodeRow(
  id: String,
  revision: Int,
  code: String
) -> NativeTranscriptRow {
  NativeTranscriptRow(
    id: id,
    revision: revision,
    body: .item(
      RenderedChatTurnItem(
        id: id,
        item: .assistantMessage(AssistantTurnMessage(content: code)),
        toolCallRecord: nil,
        generationMetrics: nil,
        assistantRenderBlocks: [
          .codeBlock(
            .init(
              id: .init(rawValue: "code"),
              language: "js",
              text: code,
              isClosed: true
            ))
        ]
      ))
  )
}

private func nativeToolRow(
  id: String,
  revision: Int,
  record: ToolCallRecord = nativeToolRecord()
) -> NativeTranscriptRow {
  return NativeTranscriptRow(
    id: id,
    revision: revision,
    body: .item(
      RenderedChatTurnItem(
        id: id,
        item: .tool(record),
        toolCallRecord: record,
        generationMetrics: nil,
        assistantRenderBlocks: []
      ))
  )
}

private func nativeToolRecord() -> ToolCallRecord {
  let request = ToolCallRequest.validated(
    raw: RawToolCallRequest(
      workspaceID: UUID(),
      sessionID: UUID(),
      toolName: .browserRefresh,
      arguments: ["hard": .bool(true)]
    ),
    payload: .browserRefresh(BrowserRefreshInput(hard: true))
  )
  return ToolCallRecord(
    request: request,
    evaluation: ToolPermissionEvaluation(
      decision: .allowed,
      reason: "Allowed for test.",
      riskLevel: .low
    ),
    state: .completed(
      .browserRefresh(
        .success(
          path: WorkspaceRelativePath(rawValue: "index.html"),
          url: "http://localhost:3000",
          hard: true
        )))
  )
}

private func nativeApprovalToolRecord(reason: String = "Needs permission.") -> ToolCallRecord {
  let request = nativeRunCommandRequest(command: "uv test")
  return ToolCallRecord(
    request: request,
    evaluation: ToolPermissionEvaluation(
      decision: .requiresApproval,
      reason: reason,
      riskLevel: .high
    ),
    state: .awaitingApproval(
      preview: ToolResultPreview(
        text: "Runs tests.",
        truncated: true,
        affectedPaths: ["Package.swift"]
      ))
  )
}

private func nativeCompletedCommandToolRecord() -> ToolCallRecord {
  let request = nativeRunCommandRequest(command: "swift test")
  return ToolCallRecord(
    request: request,
    evaluation: ToolPermissionEvaluation(
      decision: .allowed,
      reason: "Allowed for test.",
      riskLevel: .low
    ),
    state: .completed(
      .runCommand(
        RunCommandResult(
          command: "swift test",
          timeoutSeconds: 120,
          exitCode: 0,
          durationMs: 1_000,
          stdout: ToolTextOutput(text: "Tests passed."),
          stderr: ToolTextOutput(text: "")
        )))
  )
}

private func nativeRunCommandRequest(command: String) -> ToolCallRequest {
  ToolCallRequest.validated(
    raw: RawToolCallRequest(
      workspaceID: UUID(),
      sessionID: UUID(),
      toolName: .runCommand,
      arguments: ["command": .string(command)]
    ),
    payload: .runCommand(
      RunCommandInput(
        command: command,
        timeoutSeconds: RunCommandInput.defaultTimeoutSeconds
      ))
  )
}

private func nativeTextAttachment(
  id: AttachmentID = AttachmentID(),
  displayName: String
) -> ChatAttachment {
  ChatAttachment(
    id: id,
    displayName: displayName,
    payload: .text(
      TextAttachmentPayload(
        content: "Attachment body",
        byteSize: 15,
        contentSHA256: "text-\(displayName)"
      ))
  )
}

private func nativeImageAttachment(
  id: AttachmentID = AttachmentID(),
  displayName: String,
  contentSHA256: String = "image-hash"
) -> ChatAttachment {
  ChatAttachment(
    id: id,
    displayName: displayName,
    payload: .image(
      ImageAttachmentPayload(
        mimeType: "image/png",
        byteSize: 1024,
        contentSHA256: contentSHA256
      ))
  )
}
