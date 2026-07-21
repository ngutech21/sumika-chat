import Foundation
import Testing

@testable import SumikaCore

struct AgentWorkspaceInstructionsLoaderTests {
  @Test
  func fileSelectionPrefersExactCaseAndRejectsAmbiguousFallbacks() throws {
    #expect(
      try WorkspaceInstructionsLoader.selectedFileName(
        from: ["agents.md", "AGENTS.md", "Agents.md"]
      ) == "AGENTS.md"
    )
    #expect(
      try WorkspaceInstructionsLoader.selectedFileName(from: ["agents.md"])
        == "agents.md"
    )
    #expect(
      throws: WorkspaceInstructionsLoadingError.ambiguousMatches([
        "Agents.md", "agents.md",
      ])
    ) {
      try WorkspaceInstructionsLoader.selectedFileName(
        from: ["agents.md", "Agents.md"]
      )
    }
    #expect(
      try WorkspaceInstructionsLoader.selectedFileName(from: ["README.md"])
        == nil
    )
  }

  @Test
  func loadsCaseInsensitiveRootFileAndIgnoresNestedInstructions() async throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let nestedURL = rootURL.appending(path: "nested", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: nestedURL, withIntermediateDirectories: true)
    try "nested rules".write(
      to: nestedURL.appending(path: "AGENTS.md"),
      atomically: true,
      encoding: .utf8
    )
    try "root rules".write(
      to: rootURL.appending(path: "agents.md"),
      atomically: true,
      encoding: .utf8
    )

    let result = try await WorkspaceInstructionsLoader().loadInstructions(
      from: Workspace(name: "Project", rootURL: rootURL)
    )

    guard case .found(let document) = result else {
      Issue.record("Expected root workspace instructions.")
      return
    }
    #expect(document.path == WorkspaceRelativePath(rawValue: "agents.md"))
    #expect(document.content == "root rules")
    #expect(document.contentHash.count == 64)
  }

  @Test
  func missingRootFileDoesNotUseNestedFile() async throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let nestedURL = rootURL.appending(path: "nested", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: nestedURL, withIntermediateDirectories: true)
    try "nested rules".write(
      to: nestedURL.appending(path: "AGENTS.md"),
      atomically: true,
      encoding: .utf8
    )

    let result = try await WorkspaceInstructionsLoader().loadInstructions(
      from: Workspace(name: "Project", rootURL: rootURL)
    )

    #expect(result == .missing)
  }

  @Test
  func fullHashDetectsChangesAfterTruncatedExcerpt() async throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let fileURL = rootURL.appending(path: "AGENTS.md")
    try (String(repeating: "a", count: 8_000) + "first").write(
      to: fileURL,
      atomically: true,
      encoding: .utf8
    )
    let workspace = Workspace(name: "Project", rootURL: rootURL)
    let firstResult = try await WorkspaceInstructionsLoader().loadInstructions(from: workspace)
    guard case .found(let firstDocument) = firstResult else {
      Issue.record("Expected first workspace instructions document.")
      return
    }
    let firstContext = try #require(
      WorkspaceInstructionsPromptPolicy.update(
        for: firstResult,
        in: ChatSession()
      )
    )
    let firstSnapshot = try #require(firstContext.snapshot)

    try (String(repeating: "a", count: 8_000) + "second").write(
      to: fileURL,
      atomically: true,
      encoding: .utf8
    )
    let secondResult = try await WorkspaceInstructionsLoader().loadInstructions(from: workspace)
    guard case .found(let secondDocument) = secondResult else {
      Issue.record("Expected second workspace instructions document.")
      return
    }

    #expect(firstSnapshot.excerpt.text.count == 8_000)
    #expect(firstSnapshot.truncation == .byCharacterBudget)
    #expect(firstSnapshot.budget == .workspaceInstructionsDefault)
    #expect(firstDocument.contentHash != secondDocument.contentHash)
  }

  @Test
  func loadsEmptyFileWithoutTreatingItAsMissing() async throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try Data().write(to: rootURL.appending(path: "AGENTS.md"))

    let result = try await WorkspaceInstructionsLoader().loadInstructions(
      from: Workspace(name: "Empty", rootURL: rootURL)
    )

    guard case .found(let document) = result else {
      Issue.record("Expected an empty workspace instructions document.")
      return
    }
    #expect(document.content.isEmpty)
    #expect(document.contentHash.count == 64)
  }

  @Test
  func rejectsWorkspaceEscapeThroughRootSymlink() async throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let outsideURL = FileManager.default.temporaryDirectory.appending(
      path: "outside-agents-\(UUID().uuidString).md"
    )
    defer { try? FileManager.default.removeItem(at: outsideURL) }
    try "outside rules".write(to: outsideURL, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      at: rootURL.appending(path: "AGENTS.md"),
      withDestinationURL: outsideURL
    )

    await #expect(
      throws: WorkspaceInstructionsLoadingError.pathOutsideWorkspace("AGENTS.md")
    ) {
      try await WorkspaceInstructionsLoader().loadInstructions(
        from: Workspace(name: "Escaped", rootURL: rootURL)
      )
    }
  }

  @Test
  func unreadableFileAndUninspectableRootFailExplicitly() async throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let fileURL = rootURL.appending(path: "AGENTS.md")
    try "rules".write(to: fileURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0],
      ofItemAtPath: fileURL.path(percentEncoded: false)
    )
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: fileURL.path(percentEncoded: false)
      )
    }

    await #expect(
      throws: WorkspaceInstructionsLoadingError.cannotRead("AGENTS.md")
    ) {
      try await WorkspaceInstructionsLoader().loadInstructions(
        from: Workspace(name: "Unreadable", rootURL: rootURL)
      )
    }

    let missingRootURL = FileManager.default.temporaryDirectory.appending(
      path: "missing-workspace-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    await #expect(
      throws: WorkspaceInstructionsLoadingError.cannotInspectWorkspace
    ) {
      try await WorkspaceInstructionsLoader().loadInstructions(
        from: Workspace(name: "Missing", rootURL: missingRootURL)
      )
    }
  }

  @Test
  func invalidUTF8AndNonFileMatchesFailExplicitly() async throws {
    let invalidRootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: invalidRootURL) }
    try Data([0xff, 0xfe]).write(to: invalidRootURL.appending(path: "AGENTS.md"))

    await #expect(
      throws: WorkspaceInstructionsLoadingError.invalidUTF8("AGENTS.md")
    ) {
      try await WorkspaceInstructionsLoader().loadInstructions(
        from: Workspace(name: "Invalid", rootURL: invalidRootURL)
      )
    }

    let directoryRootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directoryRootURL) }
    try FileManager.default.createDirectory(
      at: directoryRootURL.appending(path: "AGENTS.md", directoryHint: .isDirectory),
      withIntermediateDirectories: true
    )

    await #expect(
      throws: WorkspaceInstructionsLoadingError.notRegularFile("AGENTS.md")
    ) {
      try await WorkspaceInstructionsLoader().loadInstructions(
        from: Workspace(name: "Directory", rootURL: directoryRootURL)
      )
    }
  }

  @Test
  func promptPolicyUsesLatestIncludedStateForChangeAndRemoval() throws {
    let existing = try #require(
      WorkspaceInstructionsPromptContext.makeSnapshot(
        path: WorkspaceRelativePath(rawValue: "agents.md"),
        contentHash: "old-hash",
        content: "Old rules"
      )
    )
    let session = ChatSession(turns: [
      ChatTurn(
        status: .completed,
        items: [
          .userMessage(
            UserTurnMessage(
              content: "First",
              promptContext: CurrentPromptContext.empty(.focusedFileDefault)
                .appendingWorkspaceInstructions(existing)
            )
          )
        ]
      )
    ])

    let removal = try #require(
      WorkspaceInstructionsPromptPolicy.update(for: .missing, in: session)
    )
    #expect(removal == .makeRemoval(path: WorkspaceRelativePath(rawValue: "agents.md")))

    let removedSession = ChatSession(
      turns: session.turns + [
        ChatTurn(
          status: .completed,
          items: [
            .userMessage(
              UserTurnMessage(
                content: "Second",
                promptContext: CurrentPromptContext.empty(.focusedFileDefault)
                  .appendingWorkspaceInstructions(removal)
              )
            )
          ]
        )
      ])
    #expect(WorkspaceInstructionsPromptPolicy.update(for: .missing, in: removedSession) == nil)

    let changedCase = try #require(
      WorkspaceInstructionsPromptPolicy.update(
        for: .found(
          WorkspaceInstructionsDocument(
            path: WorkspaceRelativePath(rawValue: "AGENTS.md"),
            contentHash: "old-hash",
            content: "Old rules"
          )
        ),
        in: session
      )
    )
    #expect(changedCase.path == WorkspaceRelativePath(rawValue: "AGENTS.md"))
    #expect(changedCase.snapshot != nil)
  }

  private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
      path: "workspace-instructions-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
