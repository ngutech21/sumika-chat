import AppKit
import Foundation
import SumikaCore

@testable import Sumika

enum TranscriptBenchmarkTailKind: String, Codable {
  case paragraph
  case openCodeFence
}

enum TranscriptBenchmarkHarnessError: Error {
  case missingTableView
  case missingActiveRow
  case unexpectedStableRowCount(expected: Int, actual: Int)
}

@MainActor
final class TranscriptBenchmarkHarness {
  let fixture: TranscriptBenchmarkFixture
  let renderer = ChatTranscriptRenderer()
  let coordinator: AppKitChatTranscriptRepresentable.Coordinator
  let scrollView: NSScrollView
  let tableView: NSTableView
  private(set) var coldApplyMs: Double = 0

  private(set) var activeContent: String
  private(set) var stableRowIDs: Set<String> = []
  private(set) var activeRowID = ""

  init(
    fixture: TranscriptBenchmarkFixture,
    viewportWidth: Int,
    viewportHeight: Int
  ) throws {
    let coordinator = AppKitChatTranscriptRepresentable.Coordinator(
      onToggleSpeech: { _, _ in },
      onApproveToolCall: { _ in },
      onDenyToolCall: { _ in },
      onAnswerAskUser: { _, _ in }
    )
    let scrollView = coordinator.makeScrollView()
    scrollView.setFrameSize(
      NSSize(width: CGFloat(viewportWidth), height: CGFloat(viewportHeight))
    )
    guard let tableView = scrollView.documentView as? NSTableView else {
      throw TranscriptBenchmarkHarnessError.missingTableView
    }

    self.fixture = fixture
    activeContent = fixture.initialActiveContent
    self.coordinator = coordinator
    self.scrollView = scrollView
    self.tableView = tableView

    let coldSample = apply(
      turns: fixture.turns(activeContent: activeContent),
      trial: 0,
      iteration: -2,
      operation: "cold-apply"
    )
    coldApplyMs = coldSample.totalMs
    try updateRowIdentity()
    guard stableRowIDs.count == fixture.stableRowCount else {
      throw TranscriptBenchmarkHarnessError.unexpectedStableRowCount(
        expected: fixture.stableRowCount,
        actual: stableRowIDs.count
      )
    }
    scrollActiveRowToVisible()
  }

  func append(_ delta: String, trial: Int, iteration: Int) -> TranscriptBenchmarkSample {
    activeContent += delta
    return apply(
      turns: fixture.turns(activeContent: activeContent),
      trial: trial,
      iteration: iteration,
      operation: "stream-append"
    )
  }

  func updateAtViewportWidth(
    _ width: Int,
    trial: Int,
    iteration: Int,
    operation: String
  ) -> TranscriptBenchmarkSample {
    scrollView.setFrameSize(NSSize(width: CGFloat(width), height: scrollView.frame.height))
    return apply(
      turns: fixture.turns(activeContent: activeContent),
      trial: trial,
      iteration: iteration,
      operation: operation
    )
  }

  func cacheSnapshot() -> TranscriptBenchmarkCacheSnapshot {
    TranscriptBenchmarkCacheSnapshot(
      renderer: renderer.performanceCacheSnapshotForTesting(),
      coordinator: coordinator.performanceCacheSnapshotForTesting()
    )
  }

  private func apply(
    turns: [ChatTurn],
    trial: Int,
    iteration: Int,
    operation: String
  ) -> TranscriptBenchmarkSample {
    let totalStart = DispatchTime.now().uptimeNanoseconds

    let rendererStart = DispatchTime.now().uptimeNanoseconds
    let items = renderer.items(for: turns)
    let rendererEnd = DispatchTime.now().uptimeNanoseconds

    let rowProjectionStart = DispatchTime.now().uptimeNanoseconds
    let rows = NativeTranscriptRow.rows(for: items, showsGenerationIndicator: false)
    let rowProjectionEnd = DispatchTime.now().uptimeNanoseconds

    let appKitStart = DispatchTime.now().uptimeNanoseconds
    coordinator.update(
      rows: rows,
      accessibilityValue: "ready",
      isSpeechEnabled: false,
      activeSpeechRowID: nil,
      in: scrollView
    )
    let appKitEnd = DispatchTime.now().uptimeNanoseconds

    let heightStart = DispatchTime.now().uptimeNanoseconds
    coordinator.flushPendingHeightInvalidationForTesting()
    tableView.layoutSubtreeIfNeeded()
    scrollView.layoutSubtreeIfNeeded()
    let heightEnd = DispatchTime.now().uptimeNanoseconds

    return TranscriptBenchmarkSample(
      trial: trial,
      iteration: iteration,
      operation: operation,
      activeTailCharacters: activeContent.count,
      viewportWidth: Int(scrollView.frame.width.rounded()),
      totalMs: transcriptBenchmarkMilliseconds(since: totalStart, until: heightEnd),
      rendererMs: transcriptBenchmarkMilliseconds(since: rendererStart, until: rendererEnd),
      rowProjectionMs: transcriptBenchmarkMilliseconds(
        since: rowProjectionStart,
        until: rowProjectionEnd
      ),
      appKitUpdateMs: transcriptBenchmarkMilliseconds(since: appKitStart, until: appKitEnd),
      heightAndLayoutMs: transcriptBenchmarkMilliseconds(since: heightStart, until: heightEnd)
    )
  }

  private func updateRowIdentity() throws {
    let items = renderer.items(for: fixture.turns(activeContent: activeContent))
    guard let activeItem = items.last else {
      throw TranscriptBenchmarkHarnessError.missingActiveRow
    }
    activeRowID = activeItem.id
    stableRowIDs = Set(items.dropLast().map(\.id))
  }

  private func scrollActiveRowToVisible() {
    guard tableView.numberOfRows > 0 else {
      return
    }
    tableView.scrollRowToVisible(tableView.numberOfRows - 1)
    tableView.layoutSubtreeIfNeeded()
    scrollView.layoutSubtreeIfNeeded()
  }
}

struct TranscriptBenchmarkFixture {
  let stableTurns: [ChatTurn]
  let stableRowCount: Int
  let activeTurnID: UUID
  let activeMessageID: UUID
  let initialActiveContent: String

  func turns(activeContent: String) -> [ChatTurn] {
    stableTurns + [
      ChatTurn(
        id: activeTurnID,
        status: .running,
        items: [
          .assistantMessage(
            AssistantTurnMessage(
              id: activeMessageID,
              content: activeContent,
              deliveryStatus: .streaming
            ))
        ]
      )
    ]
  }

  static func history(
    stableRows: Int,
    tailCharacters: Int,
    tailKind: TranscriptBenchmarkTailKind
  ) -> TranscriptBenchmarkFixture {
    var turns: [ChatTurn] = []
    var remainingRows = stableRows
    var turnIndex = 0
    while remainingRows > 0 {
      var items: [ChatTurnItem] = []
      items.append(
        .userMessage(
          UserTurnMessage(
            id: fixedUUID(namespace: 10, index: turnIndex),
            content: "Stable user request \(turnIndex)."
          )))
      remainingRows -= 1
      if remainingRows > 0 {
        items.append(
          .assistantMessage(
            AssistantTurnMessage(
              id: fixedUUID(namespace: 11, index: turnIndex),
              content: stableAssistantContent(index: turnIndex),
              deliveryStatus: .complete
            )))
        remainingRows -= 1
      }
      turns.append(
        ChatTurn(
          id: fixedUUID(namespace: 12, index: turnIndex),
          status: .completed,
          items: items
        ))
      turnIndex += 1
    }
    return TranscriptBenchmarkFixture(
      stableTurns: turns,
      stableRowCount: stableRows,
      activeTurnID: fixedUUID(namespace: 13, index: stableRows),
      activeMessageID: fixedUUID(namespace: 14, index: stableRows),
      initialActiveContent: activeContent(characters: tailCharacters, kind: tailKind)
    )
  }

  static func toolHeavy(
    stableRows: Int,
    tailCharacters: Int
  ) -> TranscriptBenchmarkFixture {
    let toolItems = (0..<stableRows).map { index in
      ChatTurnItem.tool(completedCommandRecord(index: index, outputCharacters: 2_048))
    }
    return TranscriptBenchmarkFixture(
      stableTurns: [
        ChatTurn(
          id: fixedUUID(namespace: 20, index: 0),
          status: .completed,
          items: toolItems
        )
      ],
      stableRowCount: stableRows,
      activeTurnID: fixedUUID(namespace: 21, index: 0),
      activeMessageID: fixedUUID(namespace: 22, index: 0),
      initialActiveContent: activeContent(characters: tailCharacters, kind: .paragraph)
    )
  }

  static func mixed(
    stableRows: Int,
    tailCharacters: Int
  ) -> TranscriptBenchmarkFixture {
    var turns: [ChatTurn] = []
    var remainingRows = stableRows
    var turnIndex = 0
    while remainingRows > 0 {
      var items: [ChatTurnItem] = []
      if remainingRows > 0 {
        items.append(
          .userMessage(
            UserTurnMessage(
              id: fixedUUID(namespace: 30, index: turnIndex),
              content: "Mixed fixture request \(turnIndex)."
            )))
        remainingRows -= 1
      }
      if remainingRows > 0 {
        items.append(
          .assistantThinking(
            AssistantThinkingMessage(
              id: fixedUUID(namespace: 31, index: turnIndex),
              content: "Inspecting deterministic fixture \(turnIndex).",
              deliveryStatus: .complete
            )))
        remainingRows -= 1
      }
      if remainingRows > 0 {
        items.append(
          .assistantMessage(
            AssistantTurnMessage(
              id: fixedUUID(namespace: 32, index: turnIndex),
              content: mixedAssistantContent(index: turnIndex),
              deliveryStatus: .complete
            )))
        remainingRows -= 1
      }
      if remainingRows > 0 {
        items.append(.tool(completedCommandRecord(index: 10_000 + turnIndex)))
        remainingRows -= 1
      }
      turns.append(
        ChatTurn(
          id: fixedUUID(namespace: 33, index: turnIndex),
          status: .completed,
          items: items
        ))
      turnIndex += 1
    }
    return TranscriptBenchmarkFixture(
      stableTurns: turns,
      stableRowCount: stableRows,
      activeTurnID: fixedUUID(namespace: 34, index: 0),
      activeMessageID: fixedUUID(namespace: 35, index: 0),
      initialActiveContent: activeContent(characters: tailCharacters, kind: .paragraph)
    )
  }

  static func attachmentHeavy(
    stableRows: Int,
    tailCharacters: Int
  ) -> TranscriptBenchmarkFixture {
    var turns: [ChatTurn] = []
    var remainingRows = stableRows
    var turnIndex = 0
    while remainingRows > 0 {
      var items: [ChatTurnItem] = [
        .userMessage(
          UserTurnMessage(
            id: fixedUUID(namespace: 50, index: turnIndex),
            content: "Attachment fixture request \(turnIndex).",
            attachments: (0..<2).map {
              textAttachment(turnIndex: turnIndex, slot: $0, namespace: 60)
            }
          ))
      ]
      remainingRows -= 1
      if remainingRows > 0 {
        items.append(
          .assistantMessage(
            AssistantTurnMessage(
              id: fixedUUID(namespace: 52, index: turnIndex),
              content: stableAssistantContent(index: turnIndex),
              deliveryStatus: .complete
            )))
        remainingRows -= 1
      }
      turns.append(
        ChatTurn(
          id: fixedUUID(namespace: 53, index: turnIndex),
          status: .completed,
          items: items
        ))
      turnIndex += 1
    }
    return TranscriptBenchmarkFixture(
      stableTurns: turns,
      stableRowCount: stableRows,
      activeTurnID: fixedUUID(namespace: 54, index: 0),
      activeMessageID: fixedUUID(namespace: 55, index: 0),
      initialActiveContent: activeContent(characters: tailCharacters, kind: .paragraph)
    )
  }

  private static func stableAssistantContent(index: Int) -> String {
    """
    Stable assistant answer \(index).

    - deterministic item one
    - deterministic item two
    """
  }

  private static func mixedAssistantContent(index: Int) -> String {
    switch index % 3 {
    case 0:
      return """
        Mixed answer \(index).

        | Name | Value |
        | --- | --- |
        | row | \(index) |
        """
    case 1:
      return """
        Mixed answer \(index).

        > A deterministic quote with **emphasis**.
        """
    default:
      return """
        Mixed answer \(index).

        ```swift
        let value = \(index)
        """
    }
  }

  private static func textAttachment(
    turnIndex: Int,
    slot: Int,
    namespace: Int
  ) -> ChatAttachment {
    ChatAttachment(
      id: fixedUUID(namespace: namespace + slot, index: turnIndex),
      displayName: "fixture-\(turnIndex)-\(slot).txt",
      payload: .text(
        TextAttachmentPayload(
          content: "Deterministic attachment \(turnIndex)-\(slot).",
          byteSize: 4_096,
          contentSHA256: "benchmark-\(namespace)-\(turnIndex)-\(slot)"
        )),
      createdAt: Date(timeIntervalSince1970: 0)
    )
  }

  private static func activeContent(
    characters: Int,
    kind: TranscriptBenchmarkTailKind
  ) -> String {
    switch kind {
    case .paragraph:
      return repeatedPrefix(
        seed: "Streaming markdown remains one uninterrupted deterministic paragraph. ",
        characters: characters
      )
    case .openCodeFence:
      let prefix = "```swift\n"
      guard characters > prefix.count else {
        return String(prefix.prefix(characters))
      }
      return prefix
        + repeatedPrefix(
          seed: "let value = 1; ",
          characters: characters - prefix.count
        )
    }
  }

  private static func completedCommandRecord(
    index: Int,
    outputCharacters: Int = 256
  ) -> ToolCallRecord {
    let command = "printf benchmark-\(index)"
    let requestID = fixedUUID(namespace: 40, index: index)
    let request = ToolCallRequest.validated(
      raw: RawToolCallRequest(
        id: requestID,
        workspaceID: fixedUUID(namespace: 41, index: 0),
        sessionID: fixedUUID(namespace: 42, index: 0),
        toolName: .runCommand,
        arguments: ["command": .string(command)]
      ),
      payload: .runCommand(
        RunCommandInput(
          command: command,
          timeoutSeconds: RunCommandInput.defaultTimeoutSeconds
        ))
    )
    let output = repeatedPrefix(
      seed: "tool-output-\(index) ",
      characters: outputCharacters
    )
    return ToolCallRecord(
      request: request,
      evaluation: ToolPermissionEvaluation(
        decision: .allowed,
        reason: "Allowed for deterministic benchmark.",
        riskLevel: .low
      ),
      state: .completed(
        .runCommand(
          RunCommandResult(
            command: command,
            timeoutSeconds: RunCommandInput.defaultTimeoutSeconds,
            exitCode: 0,
            durationMs: 1,
            stdout: ToolTextOutput(text: output),
            stderr: ToolTextOutput(text: "")
          )))
    )
  }

  private static func repeatedPrefix(seed: String, characters: Int) -> String {
    guard characters > 0 else {
      return ""
    }
    let repetitions = characters / max(seed.count, 1) + 1
    return String(String(repeating: seed, count: repetitions).prefix(characters))
  }

  private static func fixedUUID(namespace: Int, index: Int) -> UUID {
    let value = UInt64(namespace) * 1_000_000 + UInt64(index)
    let string = String(format: "00000000-0000-4000-8000-%012llx", value)
    guard let uuid = UUID(uuidString: string) else {
      preconditionFailure("Invalid deterministic benchmark UUID: \(string)")
    }
    return uuid
  }
}
