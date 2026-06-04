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
    #expect(
      write.payload
        == .writeFile(WriteFileInput(path: "Sources/App.swift", content: "let value = 1")))
    #expect(
      edit.payload
        == .editFile(
          EditFileInput(path: "Sources/App.swift", oldText: "old", newText: "new")))
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
  func payloadMatchingAllowsOnlyInvalidPayloadsToKeepOriginalToolName() {
    #expect(ToolCallPayload.readFile(ReadFileInput(path: "README.md")).matches(.readFile))
    #expect(ToolCallPayload.showFile(ReadFileInput(path: "README.md")).matches(.showFile))
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
      rawText: "<action name=\"\(toolName.rawValue)\">...</action>",
      createdAt: Date(timeIntervalSince1970: 1)
    )
  }
}
