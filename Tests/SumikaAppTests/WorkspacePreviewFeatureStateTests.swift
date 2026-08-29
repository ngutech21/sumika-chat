import Foundation
import SumikaCore
import SumikaTestSupport
import Testing

@testable import SumikaApp

@Suite(TemporaryDirectoryTrait(named: "sumika-workspace-preview-tests"))
@MainActor
struct WorkspacePreviewFeatureStateTests {
  @Test
  func htmlPreviewReplacesFilePreviewAndRefreshesRequestID() throws {
    let workspace = try makeWorkspace()
    try "plain text".write(
      to: workspace.rootURL.appending(path: "notes.txt", directoryHint: .notDirectory),
      atomically: true,
      encoding: .utf8
    )
    try "<!doctype html>".write(
      to: workspace.rootURL.appending(path: "index.html", directoryHint: .notDirectory),
      atomically: true,
      encoding: .utf8
    )
    let state = WorkspacePreviewFeatureState()
    #expect(state.showFilePreview(path: "notes.txt", in: workspace))
    let initialRequestID = state.htmlPreviewRequestID

    #expect(state.showHTMLPreview(path: "index.html", in: workspace))

    guard case .html(let preview) = state.preview else {
      Issue.record("Expected the HTML preview to be the single active preview")
      return
    }
    #expect(preview.relativePath == WorkspaceRelativePath(rawValue: "index.html"))
    #expect(state.htmlPreviewRequestID != initialRequestID)
    #expect(state.isVisible)
    #expect(state.errorMessage == nil)
  }

  @Test
  func filePreviewReplacesHTMLPreview() throws {
    let workspace = try makeWorkspace()
    try "<!doctype html>".write(
      to: workspace.rootURL.appending(path: "index.html", directoryHint: .notDirectory),
      atomically: true,
      encoding: .utf8
    )
    try "plain text".write(
      to: workspace.rootURL.appending(path: "notes.txt", directoryHint: .notDirectory),
      atomically: true,
      encoding: .utf8
    )
    let state = WorkspacePreviewFeatureState()
    #expect(state.showHTMLPreview(path: "index.html", in: workspace))

    #expect(state.showFilePreview(path: "notes.txt", in: workspace))

    guard case .file(let preview) = state.preview else {
      Issue.record("Expected the file preview to replace the HTML preview")
      return
    }
    #expect(preview.relativePath == WorkspaceRelativePath(rawValue: "notes.txt"))
    #expect(state.isVisible)
    #expect(state.errorMessage == nil)
  }

  @Test
  func closePreviewClearsTheSingleActivePreview() throws {
    let workspace = try makeWorkspace()
    try "<!doctype html>".write(
      to: workspace.rootURL.appending(path: "index.html", directoryHint: .notDirectory),
      atomically: true,
      encoding: .utf8
    )
    try "plain text".write(
      to: workspace.rootURL.appending(path: "notes.txt", directoryHint: .notDirectory),
      atomically: true,
      encoding: .utf8
    )
    let state = WorkspacePreviewFeatureState()
    #expect(state.showHTMLPreview(path: "index.html", in: workspace))
    state.closePreview()
    #expect(!state.isVisible)

    #expect(state.showFilePreview(path: "notes.txt", in: workspace))
    state.closePreview()
    #expect(!state.isVisible)
  }

  @Test
  func skillPreviewUsesPersistedMarkdownBodyAndReplacesHTMLPreview() throws {
    let workspace = try makeWorkspace()
    try "<!doctype html>".write(
      to: workspace.rootURL.appending(path: "index.html", directoryHint: .notDirectory),
      atomically: true,
      encoding: .utf8
    )
    let state = WorkspacePreviewFeatureState()
    #expect(state.showHTMLPreview(path: "index.html", in: workspace))
    let rawContent = """
      ---
      name: code-review
      description: Review the current diff.
      ---
      # Review steps

      - Inspect the diff.
      """

    state.showSkillPreview(
      skillRequest(
        name: "code-review",
        displayName: "Code Review",
        content: rawContent
      ))

    guard case .skill(let preview) = state.preview else {
      Issue.record("Expected the Skill preview to replace the HTML preview")
      return
    }
    #expect(preview.title == "Code Review")
    #expect(preview.portablePath == ".agents/skills/code-review/SKILL.md")
    #expect(preview.rawContent == rawContent)
    #expect(
      preview.content
        == .markdown(
          """
          # Review steps

          - Inspect the diff.
          """))
  }

  @Test
  func filePreviewReplacesSkillPreview() throws {
    let workspace = try makeWorkspace()
    try "plain text".write(
      to: workspace.rootURL.appending(path: "notes.txt", directoryHint: .notDirectory),
      atomically: true,
      encoding: .utf8
    )
    let state = WorkspacePreviewFeatureState()
    state.showSkillPreview(
      skillRequest(
        name: "review",
        displayName: "Review",
        content: "---\nname: review\ndescription: Review changes.\n---\nInstructions"
      ))

    #expect(state.showFilePreview(path: "notes.txt", in: workspace))

    guard case .file(let preview) = state.preview else {
      Issue.record("Expected the file preview to replace the Skill preview")
      return
    }
    #expect(preview.content == "plain text")
  }

  @Test
  func skillPreviewFallsBackToRawPersistedSourceWhenFormattingFails() {
    let rawContent = "not valid skill frontmatter"
    let state = WorkspacePreviewFeatureState()

    state.showSkillPreview(
      skillRequest(name: "review", displayName: "Review", content: rawContent)
    )

    guard case .skill(let preview) = state.preview else {
      Issue.record("Expected a Skill preview")
      return
    }
    #expect(preview.rawContent == rawContent)
    #expect(preview.content == .unformatted(rawContent))
  }

  @Test
  func skillPreviewShowsEmptyInstructionsStateForFrontmatterOnlySnapshot() {
    let state = WorkspacePreviewFeatureState()

    state.showSkillPreview(
      skillRequest(
        name: "review",
        displayName: "Review",
        content: "---\nname: review\ndescription: Review changes.\n---\n\n"
      ))

    guard case .skill(let preview) = state.preview else {
      Issue.record("Expected a Skill preview")
      return
    }
    #expect(preview.content == .empty)
  }

  @Test
  func previewFailureIsOwnedAndClearedByPreviewState() throws {
    let workspace = try makeWorkspace()
    let state = WorkspacePreviewFeatureState()

    #expect(!state.showHTMLPreview(path: "missing.html", in: workspace))
    #expect(state.errorMessage != nil)

    try "<!doctype html>".write(
      to: workspace.rootURL.appending(path: "index.html", directoryHint: .notDirectory),
      atomically: true,
      encoding: .utf8
    )

    #expect(state.showHTMLPreview(path: "index.html", in: workspace))
    #expect(state.errorMessage == nil)
  }

  private func makeWorkspace() throws -> Workspace {
    let rootURL = try scopedTemporaryDirectory().appending(
      path: UUID().uuidString,
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    return Workspace(
      name: "Project",
      rootURL: URL(filePath: Workspace.normalizedPath(for: rootURL))
    )
  }

  private func skillRequest(
    name: String,
    displayName: String,
    content: String
  ) -> SkillPreviewRequest {
    SkillPreviewRequest(
      skill: ActivatedSkill(
        id: SkillID(scope: .project, name: name),
        portablePath: ".agents/skills/\(name)/SKILL.md",
        contentHash: ChatAttachmentStore.contentSHA256(for: Data(content.utf8)),
        content: content
      ),
      displayName: displayName
    )
  }
}
