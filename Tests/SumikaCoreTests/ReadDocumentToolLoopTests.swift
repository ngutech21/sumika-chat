import Foundation
import SumikaTestSupport
import Testing

@testable import SumikaCore

@Suite(TemporaryDirectoryTrait(named: "read-document-tool-loop"))
struct ReadDocumentToolLoopTests {
  @Test(arguments: [false, true])
  func repeatedDocumentsConvertOnceAndBlockSecondReplay(sameBatch: Bool) async throws {
    let workspace = try makeWorkspace()
    try FileManager.default.createSymbolicLink(
      at: workspace.rootURL.appending(path: "alias.pdf"),
      withDestinationURL: workspace.rootURL.appending(path: "report.pdf"))
    let converter = CountingDocumentConverter()
    let orchestrator = ToolOrchestrator.agent(
      todoWriteEnabled: false, documentMarkdownConverter: converter)
    let paths = ["report.pdf", "./report.pdf", "alias.pdf"]
    var records: [ToolCallRecord] = []
    var lastStep: ChatWorkflowStep?
    for batch in sameBatch ? [paths] : paths.map({ [$0] }) {
      let result = try await read(
        batch, in: workspace, using: orchestrator, after: records.map(ChatTurnItem.tool))
      records += result.records
      lastStep = result.step
    }

    #expect(await converter.callCount == 1)
    #expect(records.count == 3)
    let first = try #require(records.first)
    guard case .readDocument(.success(let content)) = first.resultPayload,
      case .duplicateToolCall(let replay) = records[1].resultPayload,
      case .duplicateToolCall(let blocked) = records[2].resultPayload
    else {
      Issue.record("Expected one document conversion followed by two duplicate records")
      return
    }
    #expect(content.markdown == "original document")
    #expect(replay.previousCallID == first.id)
    #expect(!replay.blocked)
    #expect(
      replay.replayedObservation
        == ToolResultProjector.project(
          payload: try #require(first.resultPayload), request: first.request
        ).observation)
    #expect(blocked.previousCallID == first.id)
    #expect(blocked.blocked)
    #expect(blocked.replayedObservation == nil)
    guard case .resumeGeneration(_, let mode) = lastStep?.continuation else {
      Issue.record("Expected final generation after the second replay")
      return
    }
    #expect(mode == .afterToolResultFinal)
  }

  @Test(arguments: ["write", "edit", "command", "other-file"])
  func workspaceMutationsInvalidateDocumentReuse(mutation: String) async throws {
    let workspace = try makeWorkspace()
    let converter = CountingDocumentConverter()
    let orchestrator = ToolOrchestrator.agent(
      todoWriteEnabled: false, documentMarkdownConverter: converter)
    let first = try await read(["report.pdf"], in: workspace, using: orchestrator)
    let toolName: ToolName
    let arguments: ToolCallArguments
    switch mutation {
    case "edit":
      toolName = .editFile
      arguments = [
        "path": .string("./report.pdf"), "old_text": .string("original"),
        "new_text": .string("changed"),
      ]
    case "command":
      toolName = .runCommand
      arguments = ["command": .string("printf changed")]
    default:
      toolName = .writeFile
      arguments = [
        "path": .string(mutation == "other-file" ? "notes.txt" : "./report.pdf"),
        "content": .string("changed document"),
      ]
    }
    let change = await orchestrator.executeApproved(
      request: RawToolCallRequest(
        workspaceID: workspace.id, sessionID: workspace.sessions[0].id,
        toolName: toolName, arguments: arguments),
      workspace: workspace)
    #expect(change.status == .completed)
    let result = try await read(
      ["report.pdf"], in: workspace, using: orchestrator,
      after: (first.records + [change]).map(ChatTurnItem.tool))

    let record = try #require(result.records.first)
    if mutation == "other-file" {
      #expect(await converter.callCount == 1)
      guard case .duplicateToolCall = record.resultPayload else {
        Issue.record("An unrelated file write must not invalidate the document")
        return
      }
    } else {
      #expect(await converter.callCount == 2)
      guard case .readDocument(.success(let content)) = record.resultPayload else {
        Issue.record("Expected a fresh document read after a workspace mutation")
        return
      }
      #expect(
        content.markdown == (mutation == "command" ? "original document" : "changed document"))
    }
  }

  @Test
  func failedConversionsAreRetriedAndReuseDoesNotCrossTurns() async throws {
    let workspace = try makeWorkspace()
    let converter = CountingDocumentConverter(failFirstCall: true)
    let orchestrator = ToolOrchestrator.agent(
      todoWriteEnabled: false, documentMarkdownConverter: converter)
    let result = try await read(["report.pdf", "report.pdf"], in: workspace, using: orchestrator)
    #expect(result.records.map(\.status) == [.failed, .completed])
    #expect(await converter.callCount == 2)

    let next = try await read(
      ["report.pdf"], in: workspace, using: orchestrator,
      after: result.records.map(ChatTurnItem.tool) + [.userMessage(.init(content: "Read again"))])
    #expect(next.records.first?.status == .completed)
    #expect(await converter.callCount == 3)
  }

  @Test(arguments: ["absolute", "file-url", "traversal", "symlink-escape"])
  func previousSuccessCannotBypassDocumentPathDenial(pathKind: String) async throws {
    let workspace = try makeWorkspace()
    let converter = CountingDocumentConverter()
    let orchestrator = ToolOrchestrator.agent(
      todoWriteEnabled: false, documentMarkdownConverter: converter)
    let first = try await read(["report.pdf"], in: workspace, using: orchestrator)
    let source = workspace.rootURL.appending(path: "report.pdf")
    let path: String
    switch pathKind {
    case "absolute": path = source.path
    case "file-url": path = source.absoluteString
    case "traversal": path = "nested/../report.pdf"
    default:
      let outside = workspace.rootURL.deletingLastPathComponent().appending(path: "outside.pdf")
      try Data("outside document".utf8).write(to: outside)
      try FileManager.default.removeItem(at: source)
      try FileManager.default.createSymbolicLink(at: source, withDestinationURL: outside)
      path = "report.pdf"
    }
    let result = try await read(
      [path], in: workspace, using: orchestrator, after: first.records.map(ChatTurnItem.tool))
    #expect(result.records.first?.status == .denied)
    #expect(await converter.callCount == 1)
  }

  private func makeWorkspace() throws -> Workspace {
    let root = try scopedTemporaryDirectory().appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("original document".utf8).write(to: root.appending(path: "report.pdf"))
    return Workspace(
      name: "Documents", rootURL: root,
      sessions: [
        ChatSession(turns: [
          ChatTurn(status: .running, items: [.userMessage(.init(content: "Analyze report"))])
        ])
      ])
  }

  private func read(
    _ paths: [String], in workspace: Workspace, using orchestrator: ToolOrchestrator,
    after items: [ChatTurnItem] = []
  ) async throws -> (step: ChatWorkflowStep, records: [ToolCallRecord]) {
    let session = workspace.sessions[0]
    let turn = session.turns[0]
    let assistant = AssistantTurnMessage(content: "")
    let step = try #require(
      try await ToolLoopCoordinator().run(
        ToolLoopRequest(
          workspace: workspace, sessionID: session.id, turnID: turn.id,
          assistantMessageID: assistant.id,
          items: turn.items + items + [.assistantMessage(assistant)],
          nativeToolCalls: paths.map {
            ChatRuntimeToolCall(name: "read_document", arguments: ["path": .string($0)])
          }),
        using: orchestrator))
    let records = step.events.compactMap { event -> ToolCallRecord? in
      guard case .toolCallAppended(let record, _) = event else { return nil }
      return record
    }
    return (step, records)
  }
}

private actor CountingDocumentConverter: DocumentMarkdownConverting {
  private(set) var callCount = 0
  let failFirstCall: Bool

  init(failFirstCall: Bool = false) {
    self.failFirstCall = failFirstCall
  }

  func markdown(from data: Data) async throws -> String {
    callCount += 1
    if failFirstCall && callCount == 1 { throw DocumentMarkdownConversionError.needsOCR }
    return try #require(String(data: data, encoding: .utf8))
  }
}
