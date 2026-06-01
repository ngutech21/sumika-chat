import Foundation
import Testing

@testable import local_coder

struct ToolPermissionTests {
  @Test
  func workspaceResolvesRelativeAbsoluteAndFileURLPathsInsideRoot() throws {
    let rootURL = try makeTemporaryDirectory()
    let workspace = Workspace(name: "Project", rootURL: rootURL)
    let nestedURL = rootURL.appending(path: "Sources/File.swift")
    try FileManager.default.createDirectory(
      at: nestedURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "let value = 1".write(to: nestedURL, atomically: true, encoding: .utf8)

    #expect(try workspace.resolveAllowedPath("Sources/File.swift") == nestedURL)
    #expect(try workspace.resolveAllowedPath(nestedURL.path(percentEncoded: false)) == nestedURL)
    #expect(try workspace.resolveAllowedPath(nestedURL.absoluteString) == nestedURL)
    #expect(try workspace.resolveAllowedPath(".") == rootURL)
  }

  @Test
  func workspaceRejectsPathsOutsideRoot() throws {
    let rootURL = try makeTemporaryDirectory()
    let outsideURL = try makeTemporaryDirectory()
    let workspace = Workspace(name: "Project", rootURL: rootURL)

    #expect(throws: WorkspacePathResolutionError.pathOutsideWorkspace) {
      try workspace.resolveAllowedPath("../outside.txt")
    }
    #expect(throws: WorkspacePathResolutionError.pathOutsideWorkspace) {
      try workspace.resolveAllowedPath(outsideURL.path(percentEncoded: false))
    }
    #expect(throws: WorkspacePathResolutionError.pathOutsideWorkspace) {
      try workspace.resolveAllowedPath(rootURL.path(percentEncoded: false) + "-sibling/file.txt")
    }
    #expect(throws: WorkspacePathResolutionError.emptyPath) {
      try workspace.resolveAllowedPath(" ")
    }
    #expect(throws: WorkspacePathResolutionError.unsupportedURLScheme("https")) {
      try workspace.resolveAllowedPath("https://example.com/file.txt")
    }
  }

  @Test
  func workspaceRejectsSymlinkEscapes() throws {
    let rootURL = try makeTemporaryDirectory()
    let outsideURL = try makeTemporaryDirectory()
    let symlinkURL = rootURL.appending(path: "outside-link")
    try FileManager.default.createSymbolicLink(
      at: symlinkURL,
      withDestinationURL: outsideURL
    )
    let workspace = Workspace(name: "Project", rootURL: rootURL)

    #expect(throws: WorkspacePathResolutionError.pathOutsideWorkspace) {
      try workspace.resolveAllowedPath("outside-link/secret.txt")
    }
  }

  @Test
  func evaluatorAllowsReadAndListInsideWorkspace() throws {
    let rootURL = try makeTemporaryDirectory()
    let workspace = Workspace(name: "Project", rootURL: rootURL)
    let evaluator = ToolPermissionEvaluator()

    let listEvaluation = evaluator.evaluate(
      request(toolName: .listFiles, workspace: workspace, arguments: [:]),
      in: workspace
    )
    let readEvaluation = evaluator.evaluate(
      request(
        toolName: .readFile,
        workspace: workspace,
        arguments: ["path": .string("README.md")]
      ),
      in: workspace
    )

    #expect(listEvaluation.decision == .allowed)
    #expect(listEvaluation.riskLevel == .low)
    #expect(listEvaluation.normalizedPaths == [rootURL.path(percentEncoded: false)])
    #expect(readEvaluation.decision == .allowed)
    #expect(
      readEvaluation.normalizedPaths == [
        rootURL.appending(path: "README.md").path(percentEncoded: false)
      ])
    #expect(!readEvaluation.reason.isEmpty)
  }

  @Test
  func evaluatorRequiresApprovalForWorkspaceMutationsAndCommands() throws {
    let rootURL = try makeTemporaryDirectory()
    let workspace = Workspace(name: "Project", rootURL: rootURL)
    let evaluator = ToolPermissionEvaluator()

    let writeEvaluation = evaluator.evaluate(
      request(
        toolName: .writeFile,
        workspace: workspace,
        arguments: ["path": .string("Sources/File.swift")]
      ),
      in: workspace
    )
    let patchEvaluation = evaluator.evaluate(
      request(
        toolName: .applyPatch,
        workspace: workspace,
        arguments: ["affectedPaths": .array([.string("Sources/File.swift")])]
      ),
      in: workspace
    )
    let commandEvaluation = evaluator.evaluate(
      request(
        toolName: .runCommand,
        workspace: workspace,
        arguments: ["workingDirectory": .string(".")]
      ),
      in: workspace
    )

    #expect(writeEvaluation.decision == .requiresApproval)
    #expect(writeEvaluation.riskLevel == .high)
    #expect(
      writeEvaluation.normalizedPaths == [
        rootURL.appending(path: "Sources/File.swift").path(percentEncoded: false)
      ])
    #expect(patchEvaluation.decision == .requiresApproval)
    #expect(commandEvaluation.decision == .requiresApproval)
    #expect(commandEvaluation.normalizedPaths == [rootURL.path(percentEncoded: false)])
  }

  @Test
  func evaluatorDeniesUnsafeOrIncompleteRequests() throws {
    let rootURL = try makeTemporaryDirectory()
    let outsideURL = try makeTemporaryDirectory()
    let workspace = Workspace(name: "Project", rootURL: rootURL)
    let evaluator = ToolPermissionEvaluator()

    let missingPatchPaths = evaluator.evaluate(
      request(toolName: .applyPatch, workspace: workspace, arguments: [:]),
      in: workspace
    )
    let outsideCommand = evaluator.evaluate(
      request(
        toolName: .runCommand,
        workspace: workspace,
        arguments: ["workingDirectory": .string(outsideURL.path(percentEncoded: false))]
      ),
      in: workspace
    )
    let unknownTool = evaluator.evaluate(
      request(
        toolName: ToolName(canonicalizing: "shell-exec"),
        workspace: workspace,
        arguments: ["path": .string(".")]
      ),
      in: workspace
    )

    #expect(missingPatchPaths.decision == .denied)
    #expect(missingPatchPaths.reason == "apply_patch requires affectedPaths.")
    #expect(outsideCommand.decision == .denied)
    #expect(outsideCommand.normalizedPaths.isEmpty)
    #expect(unknownTool.decision == .denied)
    #expect(unknownTool.riskLevel == .high)
  }

  @Test
  func evaluatorDeniesRequestsForAnotherWorkspace() throws {
    let workspace = Workspace(name: "Project", rootURL: try makeTemporaryDirectory())
    let otherWorkspace = Workspace(name: "Other", rootURL: try makeTemporaryDirectory())
    let evaluator = ToolPermissionEvaluator()

    let evaluation = evaluator.evaluate(
      request(
        toolName: .readFile,
        workspace: otherWorkspace,
        arguments: ["path": .string("README.md")]
      ),
      in: workspace
    )

    #expect(evaluation.decision == .denied)
    #expect(evaluation.riskLevel == .high)
    #expect(evaluation.normalizedPaths.isEmpty)
  }

  @Test
  func toolNameCanonicalizesExternalNames() {
    #expect(ToolName(canonicalizing: "READ-FILE").rawValue == "read_file")
    #expect(ToolName(canonicalizing: "run command").rawValue == "run_command")
  }

  @Test
  func toolNameCodableUsesStableSnakeCaseString() throws {
    let data = try JSONEncoder().encode(ToolName(canonicalizing: "READ-FILE"))
    let encoded = try #require(String(data: data, encoding: .utf8))
    let decoded = try JSONDecoder().decode(ToolName.self, from: Data(#""write-file""#.utf8))

    #expect(encoded == #""read_file""#)
    #expect(decoded == .writeFile)
  }

  private func request(
    toolName: ToolName,
    workspace: Workspace,
    arguments: ToolCallArguments
  ) -> ToolCallRequest {
    ToolCallRequest(
      workspaceID: workspace.id,
      sessionID: UUID(),
      toolName: toolName,
      arguments: arguments
    )
  }

  private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "local-coder-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return URL(filePath: Workspace.normalizedPath(for: url))
  }
}
