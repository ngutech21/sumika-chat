import Foundation
import Testing

@testable import LocalCoderCore

struct ToolCallRequestValidatorTests {
  private let validator = ToolCallRequestValidator()

  @Test
  func validatesBuiltInToolPayloads() throws {
    let registry = ToolExecutorRegistry.codingAgent.toolRegistry

    let read = validator.validate(
      raw(.readFile, arguments: ["path": .string("README.md"), "offset": .string("1")]),
      registry: registry
    )
    let show = validator.validate(
      raw(.showFile, arguments: ["path": .string("README.md"), "limit": .string("20")]),
      registry: registry
    )
    let list = validator.validate(raw(.listFiles, arguments: [:]), registry: registry)
    let glob = validator.validate(
      raw(.globFiles, arguments: ["pattern": .string("**/*.swift")]),
      registry: registry
    )
    let search = validator.validate(
      raw(
        .searchFiles,
        arguments: [
          "pattern": .string("ToolCallRequest"),
          "include": .string("*.swift"),
        ]),
      registry: registry
    )
    let diff = validator.validate(
      raw(.workspaceDiff, arguments: ["path": .string("Sources/App.swift")]),
      registry: registry
    )
    let write = validator.validate(
      raw(
        .writeFile,
        arguments: [
          "path": .string("Sources/App.swift"),
          "content": .string("let value = 1"),
        ]),
      registry: registry
    )
    let edit = validator.validate(
      raw(
        .editFile,
        arguments: [
          "path": .string("Sources/App.swift"),
          "old_text": .string("old"),
          "new_text": .string("new"),
        ]),
      registry: registry
    )
    let command = validator.validate(
      raw(
        .runCommand,
        arguments: [
          "command": .string("just test-core"),
          "timeoutSeconds": .string("120"),
          "reason": .string("Verify tests."),
        ]),
      registry: registry
    )
    let todo = validator.validate(
      raw(
        .todoWrite,
        arguments: [
          "items": .string(
            #"["Inspect affected files:true","Add todo state:false"]"#)
        ]),
      registry: registry
    )
    let askUser = validator.validate(
      raw(
        .askUser,
        arguments: [
          "question": .string("Which implementation should I use?"),
          "option1": .string("Minimal fix"),
          "option2": .string("Broader refactor"),
        ]),
      registry: registry
    )

    guard case .readFile(let readInput) = read.payload else {
      Issue.record("Expected read_file payload")
      return
    }
    #expect(readInput == ReadFileInput(path: "README.md", offset: 1))
    #expect(show.payload == .showFile(ReadFileInput(path: "README.md", limit: 20)))
    #expect(list.payload == .listFiles(ListFilesInput(path: nil)))
    #expect(glob.payload == .globFiles(GlobFilesInput(pattern: "**/*.swift", path: nil)))
    #expect(
      search.payload
        == .searchFiles(
          SearchFilesInput(pattern: "ToolCallRequest", path: nil, include: "*.swift")))
    #expect(diff.payload == .workspaceDiff(WorkspaceDiffInput(path: "Sources/App.swift")))
    #expect(
      write.payload
        == .writeFile(WriteFileInput(path: "Sources/App.swift", content: "let value = 1")))
    #expect(
      edit.payload
        == .editFile(
          EditFileInput(path: "Sources/App.swift", oldText: "old", newText: "new")))
    #expect(
      command.payload
        == .runCommand(
          RunCommandInput(command: "just test-core", timeoutSeconds: 120, reason: "Verify tests.")
        ))
    #expect(
      todo.payload
        == .todoWrite(
          TodoWriteInput(items: [
            TodoItem(id: "1", content: "Inspect affected files", status: .completed),
            TodoItem(id: "2", content: "Add todo state", status: .pending),
          ])))
    #expect(
      askUser.payload
        == .askUser(
          AskUserInput(
            question: "Which implementation should I use?",
            options: ["Minimal fix", "Broader refactor"]
          )))
  }

  @Test
  func invalidPayloadsKeepRawArgumentsAndPreciseReasons() {
    let registry = ToolExecutorRegistry.readOnly.toolRegistry
    let rawArguments: ToolCallArguments = ["path": .string("README.md")]

    let unknown = validator.validate(
      raw(ToolName(canonicalizing: "shell_exec"), arguments: rawArguments),
      registry: registry
    )
    let unavailable = validator.validate(
      raw(.writeFile, arguments: rawArguments),
      registry: registry
    )
    let missing = validator.validate(raw(.readFile, arguments: [:]), registry: registry)
    let wrongType = validator.validate(
      raw(.readFile, arguments: ["path": .number(1)]),
      registry: registry
    )
    let emptyPath = validator.validate(
      raw(.readFile, arguments: ["path": .string(" ")]),
      registry: registry
    )
    let invalidLimit = validator.validate(
      raw(.readFile, arguments: ["path": .string("README.md"), "limit": .number(0)]),
      registry: registry
    )

    #expect(invalidReason(unknown) == .unknownToolName("shell_exec"))
    #expect(invalidReason(unavailable) == .unavailableToolName("write_file"))
    #expect(invalidReason(missing) == .missingRequiredArgument("path"))
    #expect(invalidReason(wrongType)?.message.contains("Invalid argument type for path") == true)
    #expect(invalidReason(emptyPath) == .emptyPath)
    #expect(invalidReason(invalidLimit) == .invalidPagination("limit"))
    #expect(invalidInput(unknown)?.rawArguments == rawArguments)
  }

  @Test
  func invalidEditFileOldTextIsFirstClassReason() {
    let request = validator.validate(
      raw(
        .editFile,
        arguments: [
          "path": .string("Sources/App.swift"),
          "old_text": .string(""),
          "new_text": .string("new"),
        ]),
      registry: ToolExecutorRegistry.codingAgent.toolRegistry
    )

    #expect(invalidReason(request) == .emptyOldText)
  }

  @Test
  func invalidEditFileWithoutArgumentsReportsMissingRequiredArgument() {
    let request = validator.validate(
      raw(.editFile, arguments: [:]),
      registry: ToolExecutorRegistry.codingAgent.toolRegistry
    )

    #expect(invalidReason(request) == .missingRequiredArgument("path"))
  }

  @Test
  func askUserRejectsLegacyOptionsMissingRequiredOptionAndEmptyOptions() {
    let registry = ToolExecutorRegistry.codingAgent.toolRegistry
    let legacyOptions = validator.validate(
      raw(
        .askUser,
        arguments: [
          "question": .string("Choose?"),
          "options": .string(#"["Minimal fix","Broader refactor"]"#),
        ]),
      registry: registry
    )
    let missingOption2 = validator.validate(
      raw(
        .askUser,
        arguments: [
          "question": .string("Choose?"),
          "option1": .string("Only one"),
        ]),
      registry: registry
    )
    let emptyOption1 = validator.validate(
      raw(
        .askUser,
        arguments: [
          "question": .string("Choose?"),
          "option1": .string(" "),
          "option2": .string("Broader refactor"),
        ]),
      registry: registry
    )
    let emptyOption3 = validator.validate(
      raw(
        .askUser,
        arguments: [
          "question": .string("Choose?"),
          "option1": .string("Minimal fix"),
          "option2": .string("Broader refactor"),
          "option3": .string(" "),
        ]),
      registry: registry
    )
    let duplicateOptions = validator.validate(
      raw(
        .askUser,
        arguments: [
          "question": .string("Choose?"),
          "option1": .string(" Turtle "),
          "option2": .string("turtle"),
        ]),
      registry: registry
    )
    #expect(invalidReason(legacyOptions) == .unknownArguments(["options"]))
    #expect(invalidReason(missingOption2) == .missingRequiredArgument("option2"))
    #expect(
      invalidReason(emptyOption1)
        == .invalidArgumentType(
          name: "option1",
          expected: "a non-empty answer option string"
        ))
    #expect(
      invalidReason(emptyOption3)
        == .invalidArgumentType(
          name: "option3",
          expected: "omit it or provide a non-empty answer option string"
        ))
    #expect(
      invalidReason(duplicateOptions)
        == .invalidArgumentType(
          name: "options",
          expected: "unique answer option strings"
        ))
  }

  @Test
  func todoWriteAcceptsRowStringsAndCommaContainingContent() {
    let request = validator.validate(
      raw(
        .todoWrite,
        arguments: [
          "items": .string(
            #"["Inspect files, configs, and docs:true","Run tests:false"]"#)
        ]),
      registry: ToolExecutorRegistry.codingAgent.toolRegistry
    )

    #expect(
      request.payload
        == .todoWrite(
          TodoWriteInput(items: [
            TodoItem(
              id: "1",
              content: "Inspect files, configs, and docs",
              status: .completed
            ),
            TodoItem(id: "2", content: "Run tests", status: .pending),
          ])))
  }

  @Test
  func todoWriteAcceptsPlainTextRows() {
    let request = validator.validate(
      raw(
        .todoWrite,
        arguments: [
          "items": .string(
            """
            Inspect files:true
            Run tests:false
            """
          )
        ]),
      registry: ToolExecutorRegistry.codingAgent.toolRegistry
    )

    #expect(
      request.payload
        == .todoWrite(
          TodoWriteInput(items: [
            TodoItem(id: "1", content: "Inspect files", status: .completed),
            TodoItem(id: "2", content: "Run tests", status: .pending),
          ])))
  }

  @Test
  func todoWriteSplitsRowsAtTrailingDoneSuffix() {
    let request = validator.validate(
      raw(
        .todoWrite,
        arguments: [
          "items": .string(
            """
            Inspect files: configs:true
            Run tests:false
            """
          )
        ]),
      registry: ToolExecutorRegistry.codingAgent.toolRegistry
    )

    #expect(
      request.payload
        == .todoWrite(
          TodoWriteInput(items: [
            TodoItem(id: "1", content: "Inspect files: configs", status: .completed),
            TodoItem(id: "2", content: "Run tests", status: .pending),
          ])))
  }

  @Test
  func todoWriteAlsoAcceptsSemicolonDoneSuffix() {
    let request = validator.validate(
      raw(
        .todoWrite,
        arguments: [
          "items": .string(
            """
            Inspect files;true
            Run tests;false
            """
          )
        ]),
      registry: ToolExecutorRegistry.codingAgent.toolRegistry
    )

    #expect(
      request.payload
        == .todoWrite(
          TodoWriteInput(items: [
            TodoItem(id: "1", content: "Inspect files", status: .completed),
            TodoItem(id: "2", content: "Run tests", status: .pending),
          ])))
  }

  @Test
  func todoWriteStillAcceptsInternalObjectArrays() {
    let request = validator.validate(
      raw(
        .todoWrite,
        arguments: [
          "items": .array([
            .object([
              "id": .string("inspect"),
              "content": .string("Inspect affected files"),
              "status": .string("completed"),
            ]),
            .object([
              "id": .string("core"),
              "content": .string("Add todo state"),
              "status": .string("inProgress"),
            ]),
          ])
        ]),
      registry: ToolExecutorRegistry.codingAgent.toolRegistry
    )

    #expect(
      request.payload
        == .todoWrite(
          TodoWriteInput(items: [
            TodoItem(id: "inspect", content: "Inspect affected files", status: .completed),
            TodoItem(id: "core", content: "Add todo state", status: .inProgress),
          ])))
  }

  @Test
  func todoWriteValidatesItemCountContentAndDoneValue() {
    let registry = ToolExecutorRegistry.codingAgent.toolRegistry
    let noItems = validator.validate(
      raw(
        .todoWrite,
        arguments: [
          "items": .string("[]")
        ]),
      registry: registry
    )
    let oneItem = validator.validate(
      raw(
        .todoWrite,
        arguments: [
          "items": .string(#"["Only one item:false"]"#)
        ]),
      registry: registry
    )
    let oneDirectItem = validator.validate(
      raw(
        .todoWrite,
        arguments: [
          "items": .array([
            .object([
              "id": .string("only"),
              "content": .string("Only one item"),
              "status": .string("pending"),
            ])
          ])
        ]),
      registry: registry
    )
    let emptyContent = validator.validate(
      raw(
        .todoWrite,
        arguments: [
          "items": .string(#"[" :false","Valid item:false"]"#)
        ]),
      registry: registry
    )
    let sevenItems = validator.validate(
      raw(
        .todoWrite,
        arguments: [
          "items": .array(
            (0..<7).map { index in
              .string("Item \(index):false")
            })
        ]),
      registry: registry
    )
    let invalidDoneValue = validator.validate(
      raw(
        .todoWrite,
        arguments: [
          "items": .string(#"["Inspect:done","Verify:false"]"#)
        ]),
      registry: registry
    )
    let malformedRow = validator.validate(
      raw(
        .todoWrite,
        arguments: [
          "items": .string(#"["one,false","Verify:false"]"#)
        ]),
      registry: registry
    )

    #expect(invalidReason(noItems)?.message.contains("2 to 6 items") == true)
    #expect(invalidReason(oneItem)?.message.contains("2 to 6 items") == true)
    #expect(invalidReason(oneDirectItem)?.message.contains("2 to 6 items") == true)
    #expect(invalidReason(sevenItems)?.message.contains("2 to 6 items") == true)
    #expect(invalidReason(emptyContent)?.message.contains("content must not be empty") == true)
    #expect(invalidReason(invalidDoneValue)?.message.contains("content:true|false") == true)
    #expect(invalidReason(malformedRow)?.message.contains("content:true|false") == true)
  }

  @Test
  func todoWriteAcceptsEscapedRowSeparatorsWhenPlanHasMultipleItems() {
    let registry = ToolExecutorRegistry.codingAgent.toolRegistry
    let singleEscaped = validator.validate(
      raw(
        .todoWrite,
        arguments: [
          "items": .string(#"Inspect files:false\nRun tests:false"#)
        ]),
      registry: registry
    )
    let doubleEscaped = validator.validate(
      raw(
        .todoWrite,
        arguments: [
          "items": .string(#"Inspect files:true\\nRun tests:false"#)
        ]),
      registry: registry
    )

    #expect(
      singleEscaped.payload
        == .todoWrite(
          TodoWriteInput(items: [
            TodoItem(id: "1", content: "Inspect files", status: .pending),
            TodoItem(id: "2", content: "Run tests", status: .pending),
          ])))
    #expect(
      doubleEscaped.payload
        == .todoWrite(
          TodoWriteInput(items: [
            TodoItem(id: "1", content: "Inspect files", status: .completed),
            TodoItem(id: "2", content: "Run tests", status: .pending),
          ])))
  }

  @Test
  func todoWriteRejectsDirectItemFields() {
    let request = validator.validate(
      raw(
        .todoWrite,
        arguments: [
          "id": .string("inspect"),
          "status": .string("inProgress"),
          "},{content.": .string("Inspect the requested CLI project"),
        ]),
      registry: ToolExecutorRegistry.codingAgent.toolRegistry
    )

    #expect(invalidReason(request) == .unknownArguments(["id", "status", "},{content."]))
    #expect(invalidInput(request)?.rawArguments.keys.sorted() == ["id", "status", "},{content."])
  }

  @Test
  func payloadMatchingAllowsOnlyInvalidPayloadsToKeepOriginalToolName() {
    #expect(ToolCallPayload.readFile(ReadFileInput(path: "README.md")).matches(.readFile))
    #expect(ToolCallPayload.showFile(ReadFileInput(path: "README.md")).matches(.showFile))
    #expect(ToolCallPayload.workspaceDiff(WorkspaceDiffInput(path: nil)).matches(.workspaceDiff))
    #expect(
      ToolCallPayload.runCommand(RunCommandInput(command: "date", timeoutSeconds: 1)).matches(
        .runCommand))
    #expect(
      ToolCallPayload.todoWrite(
        TodoWriteInput(items: [
          TodoItem(id: "one", content: "Plan work", status: .pending),
          TodoItem(id: "two", content: "Run tests", status: .pending),
        ])
      ).matches(.todoWrite))
    #expect(!ToolCallPayload.readFile(ReadFileInput(path: "README.md")).matches(.writeFile))
    #expect(
      ToolCallPayload.invalid(
        InvalidToolInput(
          originalName: "shell_exec",
          rawArguments: [:],
          reason: .unknownToolName("shell_exec")
        )
      ).matches(ToolName(canonicalizing: "shell_exec"))
    )
  }

  private func invalidReason(_ request: ToolCallRequest) -> InvalidToolCallReason? {
    invalidInput(request)?.reason
  }

  private func invalidInput(_ request: ToolCallRequest) -> InvalidToolInput? {
    guard case .invalid(let input) = request.payload else {
      return nil
    }
    return input
  }

  private func raw(
    _ toolName: ToolName,
    arguments: ToolCallArguments
  ) -> RawToolCallRequest {
    RawToolCallRequest(
      workspaceID: UUID(),
      sessionID: UUID(),
      toolName: toolName,
      arguments: arguments,
      rawText: NativeToolCallBoundaryRenderer.renderGemma4(
        toolName: toolName.rawValue,
        arguments: arguments
      ),
      createdAt: Date(timeIntervalSince1970: 1)
    )
  }
}
