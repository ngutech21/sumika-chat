import Foundation
import Testing

@testable import LocalCoderCore

struct ToolEditExecutionTests {
  @Test
  func editFileAwaitsApprovalWithPreviewWithoutWriting() async throws {
    let workspace = try makeWorkspace()
    try write("let title = \"Old\"\n", to: "Sources/App.swift", in: workspace)

    let result = await ToolOrchestrator(executorRegistry: .codingAgent).execute(
      request: request(
        .editFile,
        workspace: workspace,
        arguments: editArguments(
          path: "Sources/App.swift",
          oldText: "let title = \"Old\"",
          newText: "let title = \"New\""
        )
      ),
      workspace: workspace
    )

    #expect(result.status == .awaitingApproval)
    #expect(result.evaluation.decision == .requiresApproval)
    #expect(result.resultPreview?.status == .success)
    #expect(result.resultPreview?.text.contains("-let title = \"Old\"") == true)
    #expect(result.resultPreview?.text.contains("+let title = \"New\"") == true)
    #expect(
      try String(contentsOf: workspace.rootURL.appending(path: "Sources/App.swift"))
        == "let title = \"Old\"\n")
  }

  @Test
  func approvedEditFileWritesSingleExactReplacement() async throws {
    let workspace = try makeWorkspace()
    try write("one\ntwo\nthree\n", to: "notes.txt", in: workspace)

    let result = await ToolOrchestrator(executorRegistry: .codingAgent).executeApproved(
      request: request(
        .editFile,
        workspace: workspace,
        arguments: editArguments(path: "notes.txt", oldText: "two", newText: "TWO")
      ),
      workspace: workspace
    )

    #expect(result.status == .completed)
    #expect(result.resultPreview?.status == .success)
    #expect(
      try String(contentsOf: workspace.rootURL.appending(path: "notes.txt")) == "one\nTWO\nthree\n")
  }

  @Test
  func editFileDeniesWorkspaceEscapes() async throws {
    let workspace = try makeWorkspace()

    let result = await ToolOrchestrator(executorRegistry: .codingAgent).execute(
      request: request(
        .editFile,
        workspace: workspace,
        arguments: editArguments(path: "../secret.txt", oldText: "old", newText: "new")
      ),
      workspace: workspace
    )

    #expect(result.status == .denied)
    #expect(result.resultPreview?.status == .denied)
  }

  @Test
  func editFileFailsBeforeApprovalForMissingAndAmbiguousOldText() async throws {
    let workspace = try makeWorkspace()
    try write("repeat\nrepeat\n", to: "repeat.txt", in: workspace)
    try write("aaa", to: "overlap.txt", in: workspace)
    try write("hello", to: "hello.txt", in: workspace)

    let missing = await executeEdit(
      path: "hello.txt",
      oldText: "absent",
      newText: "new",
      workspace: workspace
    )
    let ambiguous = await executeEdit(
      path: "repeat.txt",
      oldText: "repeat",
      newText: "value",
      workspace: workspace
    )
    let overlapping = await executeEdit(
      path: "overlap.txt",
      oldText: "aa",
      newText: "b",
      workspace: workspace
    )
    let emptyOldText = await executeEdit(
      path: "hello.txt",
      oldText: "",
      newText: "new",
      workspace: workspace
    )
    let nonUTF8 = await executeEdit(
      path: "binary.txt",
      oldText: "old",
      newText: "new",
      workspace: workspace
    )

    #expect(missing.status == .failed)
    #expect(missing.resultPreview?.text.contains("old_text was not found") == true)
    #expect(ambiguous.status == .failed)
    #expect(ambiguous.resultPreview?.text.contains("matched more than once") == true)
    #expect(overlapping.status == .failed)
    #expect(overlapping.resultPreview?.text.contains("matched more than once") == true)
  }

  @Test
  func editFileFailsBeforeApprovalForIdenticalEmptyAndInvalidText() async throws {
    let workspace = try makeWorkspace()
    try write("hello", to: "hello.txt", in: workspace)
    try Data([0xff, 0xfe]).write(to: workspace.rootURL.appending(path: "binary.txt"))

    let identical = await executeEdit(
      path: "hello.txt",
      oldText: "hello",
      newText: "hello",
      workspace: workspace
    )
    let emptyOldText = await executeEdit(
      path: "hello.txt",
      oldText: "",
      newText: "new",
      workspace: workspace
    )
    let nonUTF8 = await executeEdit(
      path: "binary.txt",
      oldText: "old",
      newText: "new",
      workspace: workspace
    )

    #expect(identical.status == .failed)
    #expect(identical.resultPreview?.text.contains("different from old_text") == true)
    #expect(emptyOldText.status == .failed)
    #expect(emptyOldText.resultPreview?.text.contains("must not be empty") == true)
    #expect(nonUTF8.status == .failed)
    #expect(nonUTF8.resultPreview?.text.contains("not valid UTF-8") == true)
  }

  @Test
  func approvedEditFileRevalidatesMissingAndAmbiguousOldText() async throws {
    let missingWorkspace = try makeWorkspace()
    try write("old", to: "notes.txt", in: missingWorkspace)
    let pendingMissing = await executeEdit(
      path: "notes.txt",
      oldText: "old",
      newText: "new",
      workspace: missingWorkspace
    )
    try write("changed", to: "notes.txt", in: missingWorkspace)

    let missing = await ToolOrchestrator(executorRegistry: .codingAgent).executeApproved(
      request: pendingMissing.request,
      workspace: missingWorkspace
    )

    let ambiguousWorkspace = try makeWorkspace()
    try write("old", to: "notes.txt", in: ambiguousWorkspace)
    let pendingAmbiguous = await executeEdit(
      path: "notes.txt",
      oldText: "old",
      newText: "new",
      workspace: ambiguousWorkspace
    )
    try write("old old", to: "notes.txt", in: ambiguousWorkspace)

    let ambiguous = await ToolOrchestrator(executorRegistry: .codingAgent).executeApproved(
      request: pendingAmbiguous.request,
      workspace: ambiguousWorkspace
    )

    #expect(pendingMissing.status == .awaitingApproval)
    #expect(missing.status == .failed)
    #expect(missing.resultPreview?.text.contains("old_text was not found") == true)
    #expect(pendingAmbiguous.status == .awaitingApproval)
    #expect(ambiguous.status == .failed)
    #expect(ambiguous.resultPreview?.text.contains("matched more than once") == true)
  }

  @Test
  func editFileIsOnlyRegisteredForCodingAgent() {
    #expect(!ToolExecutorRegistry.readOnly.definitions.map(\.name).contains(.editFile))
    #expect(ToolExecutorRegistry.codingAgent.definitions.map(\.name).contains(.editFile))
  }

  private func executeEdit(
    path: String,
    oldText: String,
    newText: String,
    workspace: Workspace
  ) async -> ToolCallRecord {
    await ToolOrchestrator(executorRegistry: .codingAgent).execute(
      request: request(
        .editFile,
        workspace: workspace,
        arguments: editArguments(path: path, oldText: oldText, newText: newText)
      ),
      workspace: workspace
    )
  }

  private func editArguments(
    path: String,
    oldText: String,
    newText: String
  ) -> ToolCallArguments {
    [
      "path": .string(path),
      "old_text": .string(oldText),
      "new_text": .string(newText),
    ]
  }

  private func request(
    _ toolName: ToolName,
    workspace: Workspace,
    arguments: ToolCallArguments
  ) -> RawToolCallRequest {
    RawToolCallRequest(
      workspaceID: workspace.id,
      sessionID: UUID(),
      toolName: toolName,
      arguments: arguments
    )
  }

  private func makeWorkspace() throws -> Workspace {
    let rootURL = FileManager.default.temporaryDirectory
      .appending(path: "local-coder-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    return Workspace(
      name: "Project",
      rootURL: URL(filePath: Workspace.normalizedPath(for: rootURL))
    )
  }

  private func write(_ content: String, to path: String, in workspace: Workspace) throws {
    let url = workspace.rootURL.appending(path: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try content.write(to: url, atomically: true, encoding: .utf8)
  }
}
