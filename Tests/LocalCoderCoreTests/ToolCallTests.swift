import Foundation
import Testing

@testable import LocalCoderCore

struct ToolCallTests {
  @Test
  func toolArgumentValueDecodesJSONScalarsCollectionsAndNull() throws {
    let data = Data(
      """
      {
        "path": "Sources/App.swift",
        "limit": 25,
        "recursive": true,
        "tags": ["swift", "ui"],
        "options": {
          "includeHidden": false
        },
        "missing": null
      }
      """.utf8)

    let arguments = try JSONDecoder().decode(ToolCallArguments.self, from: data)

    #expect(arguments["path"] == .string("Sources/App.swift"))
    #expect(arguments["limit"] == .number(25))
    #expect(arguments["recursive"] == .bool(true))
    #expect(arguments["tags"] == .array([.string("swift"), .string("ui")]))
    #expect(arguments["options"] == .object(["includeHidden": .bool(false)]))
    #expect(arguments["missing"] == .null)
  }

  @Test
  func toolArgumentValueEncodesRoundTripJSON() throws {
    let arguments: ToolCallArguments = [
      "path": .string("README.md"),
      "limit": .number(10),
      "recursive": .bool(false),
      "filters": .array([.string("swift"), .null]),
      "metadata": .object(["source": .string("test")]),
    ]

    let data = try JSONEncoder().encode(arguments)
    let decoded = try JSONDecoder().decode(ToolCallArguments.self, from: data)

    #expect(decoded == arguments)
  }

  @Test
  func toolArgumentValueDisplayValueFormatsModelFacingArguments() {
    #expect(ToolArgumentValue.string("Sources/App.swift").displayValue == "Sources/App.swift")
    #expect(ToolArgumentValue.number(42).displayValue == "42")
    #expect(ToolArgumentValue.bool(true).displayValue == "true")
    #expect(ToolArgumentValue.bool(false).displayValue == "false")
    #expect(
      ToolArgumentValue.array([.string("Sources"), .number(2), .bool(false)]).displayValue
        == "Sources, 2, false")
    #expect(ToolArgumentValue.object(["path": .string("README.md")]).displayValue == "{...}")
    #expect(ToolArgumentValue.null.displayValue == "null")
  }

  @Test
  func toolCallModelMessageSortsArgumentsForStableDisplay() {
    let request = RawToolCallRequest(
      workspaceID: UUID(),
      sessionID: UUID(),
      toolName: .readFile,
      arguments: [
        "zeta": .string("last"),
        "alpha": .string("first"),
      ]
    )

    let message = ToolCallModelMessage(rawRequest: request)

    #expect(message.arguments.map(\.name) == ["alpha", "zeta"])
    #expect(message.arguments.map(\.value) == ["first", "last"])
  }

  @Test
  func writeFileTranscriptArgumentsHideContentPayload() {
    let request = RawToolCallRequest(
      workspaceID: UUID(),
      sessionID: UUID(),
      toolName: .writeFile,
      arguments: [
        "content": .string("<html></html>"),
        "path": .string("index.html"),
      ]
    )

    let message = ToolCallModelMessage(rawRequest: request)

    #expect(message.arguments.map(\.name) == ["content", "path"])
    #expect(message.transcriptArguments.map(\.name) == ["path"])
    #expect(message.transcriptArguments.map(\.value) == ["index.html"])
  }

  @Test
  func editFileTranscriptArgumentsHideTextPayloads() {
    let request = RawToolCallRequest(
      workspaceID: UUID(),
      sessionID: UUID(),
      toolName: .editFile,
      arguments: [
        "new_text": .string("new"),
        "old_text": .string("old"),
        "path": .string("Sources/App.swift"),
      ]
    )

    let message = ToolCallModelMessage(rawRequest: request)

    #expect(message.arguments.map(\.name) == ["new_text", "old_text", "path"])
    #expect(message.transcriptArguments.map(\.name) == ["path"])
    #expect(message.transcriptArguments.map(\.value) == ["Sources/App.swift"])
  }

  @Test
  func toolCallStateDerivesCompletedStatusPayloadAndPreview() {
    let payload = ToolResultPayload.writeFile(
      .success(path: WorkspaceRelativePath(rawValue: "README.md"), bytesWritten: 12)
    )
    let state = ToolCallState.completed(payload)

    #expect(state.status == .completed)
    #expect(state.resultPayload == payload)
    #expect(state.approvalPreview == nil)
    #expect(state.preview == payload.preview)
  }

  @Test
  func toolCallStateDerivesAwaitingApprovalPreviewWithoutPayload() {
    let preview = ToolResultPreview(
      status: .success,
      text: "Will update README.md.",
      affectedPaths: ["README.md"]
    )
    let state = ToolCallState.awaitingApproval(preview: preview)

    #expect(state.status == .awaitingApproval)
    #expect(state.resultPayload == nil)
    #expect(state.approvalPreview == preview)
    #expect(state.preview == preview)
  }

  @Test
  func toolCallStateNonResultStatesHaveNoPayload() {
    let states: [ToolCallState] = [.pending, .running, .cancelled]

    for state in states {
      #expect(state.resultPayload == nil)
      #expect(state.preview == nil)
    }
  }
}
