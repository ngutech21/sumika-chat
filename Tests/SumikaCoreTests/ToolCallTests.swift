import Foundation
import Testing

@testable import SumikaCore

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
  func askUserInputCodableUsesOptionsArray() throws {
    let input = AskUserInput(
      question: "Which implementation should I use?",
      options: ["Minimal fix", "Broader refactor", "Defer"]
    )

    let data = try JSONEncoder().encode(input)
    let object = try #require(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    let decoded = try JSONDecoder().decode(AskUserInput.self, from: data)

    #expect(object["question"] as? String == "Which implementation should I use?")
    #expect(object["options"] as? [String] == ["Minimal fix", "Broader refactor", "Defer"])
    #expect(object["option1"] == nil)
    #expect(object["option2"] == nil)
    #expect(decoded == input)
  }

  @Test
  func todoWriteInputCodableUsesNumberedFieldsAndRejectsUnrepresentableItems() throws {
    let input = TodoWriteInput(items: [
      TodoItem(id: "inspect", content: "Inspect files", status: .completed),
      TodoItem(id: "test", content: "Run tests", status: .pending),
    ])

    let data = try JSONEncoder().encode(input)
    let object = try #require(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    let decoded = try JSONDecoder().decode(TodoWriteInput.self, from: data)

    #expect(object["item1"] as? String == "Inspect files")
    #expect(object["done1"] as? Bool == true)
    #expect(object["item2"] as? String == "Run tests")
    #expect(object["done2"] as? Bool == false)
    #expect(object["items"] == nil)
    #expect(
      decoded
        == TodoWriteInput(items: [
          TodoItem(id: "1", content: "Inspect files", status: .completed),
          TodoItem(id: "2", content: "Run tests", status: .pending),
        ]))

    let inProgressInput = TodoWriteInput(items: [
      TodoItem(id: "inspect", content: "Inspect files", status: .completed),
      TodoItem(id: "test", content: "Run tests", status: .inProgress),
    ])
    do {
      _ = try JSONEncoder().encode(inProgressInput)
      Issue.record("Expected todo_write encoding to reject inProgress.")
    } catch TodoStateValidationError.unsupportedTodoWriteStatus(let id, let status) {
      #expect(id == "test")
      #expect(status == .inProgress)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    let sevenItemsInput = TodoWriteInput(
      items: (1...7).map { index in
        TodoItem(id: "\(index)", content: "Item \(index)", status: .pending)
      })
    do {
      _ = try JSONEncoder().encode(sevenItemsInput)
      Issue.record("Expected todo_write encoding to reject more than six items.")
    } catch TodoStateValidationError.invalidItemCount(let count) {
      #expect(count == 7)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
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
  func runtimeToolCallIDRoundTripsUUID() throws {
    let uuid = try #require(UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF"))
    let runtimeID = RuntimeToolCallID.string(for: uuid)

    #expect(runtimeID == "call_0123456789abcdef0123456789abcdef")
    #expect(RuntimeToolCallID.uuid(from: runtimeID) == uuid)
    #expect(RuntimeToolCallID.uuid(from: "call_not-a-uuid") == nil)
    #expect(RuntimeToolCallID.uuid(from: nil) == nil)
  }

  @Test
  func toolCallModelMessagePreservesRawArgumentsForModelReplay() {
    let request = RawToolCallRequest(
      workspaceID: UUID(),
      sessionID: UUID(),
      toolName: .readFile,
      arguments: [
        "line": .number(12),
        "path": .string("README.md"),
      ]
    )

    let message = ToolCallModelMessage(rawRequest: request)

    #expect(message.rawArguments == request.arguments)
    #expect(message.arguments.map(\.name) == ["line", "path"])
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
  func nativeModelContextBoundaryRedactsWriteAndEditPayloads() {
    let fileContent = "<html><body>Generated page</body></html>"
    let oldText = "let title = \"Old\""
    let newText = "let title = \"New\""

    let boundary = NativeToolCallBoundaryRenderer.renderModelContextGemma4(
      [
        ChatRuntimeToolCall(name: "read_file", arguments: ["path": .string("README.md")]),
        ChatRuntimeToolCall(
          name: "WRITE-FILE",
          arguments: [
            "path": .string("index.html"),
            "content": .string(fileContent),
          ]
        ),
        ChatRuntimeToolCall(
          name: "EDIT-FILE",
          arguments: [
            "path": .string("Sources/App.swift"),
            "old_text": .string(oldText),
            "new_text": .string(newText),
          ]
        ),
      ],
      registry: ToolExecutorRegistry.codingAgent.toolRegistry
    )

    #expect(boundary.contains("<|tool_call>call:read_file{path:<|\"|>README.md<|\"|>}<tool_call|>"))
    #expect(boundary.contains("Tool call write_file requested."))
    #expect(boundary.contains("Path:\nindex.html"))
    #expect(boundary.contains("Tool call edit_file requested."))
    #expect(boundary.contains("Path:\nSources/App.swift"))
    #expect(boundary.contains("Payload omitted from history."))
    #expect(!boundary.contains(fileContent))
    #expect(!boundary.contains(oldText))
    #expect(!boundary.contains(newText))
    #expect(!boundary.contains("content:"))
    #expect(!boundary.contains("old_text:"))
    #expect(!boundary.contains("new_text:"))
  }

  @Test
  func runCommandTranscriptArgumentsHideWorkingDirectory() {
    let request = RawToolCallRequest(
      workspaceID: UUID(),
      sessionID: UUID(),
      toolName: .runCommand,
      arguments: [
        "command": .string("just test-core"),
        "cwd": .string("/tmp/project"),
        "reason": .string("Verify core behavior."),
        "timeoutSeconds": .number(120),
        "working_directory": .string("/tmp/project"),
      ]
    )

    let message = ToolCallModelMessage(rawRequest: request)

    #expect(message.transcriptArguments.map(\.name) == ["command", "reason", "timeoutSeconds"])
    #expect(
      message.transcriptArguments.map(\.value) == [
        "just test-core",
        "Verify core behavior.",
        "120",
      ])
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
    let states: [ToolCallState] = [
      .pending,
      .awaitingApproval(preview: nil),
      .awaitingUserAnswer,
      .running,
      .cancelled,
    ]

    for state in states {
      #expect(state.resultPayload == nil)
      #expect(state.preview == nil)
    }
  }
}
