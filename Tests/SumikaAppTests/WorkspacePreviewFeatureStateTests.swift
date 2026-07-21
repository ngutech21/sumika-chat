import Foundation
import SumikaCore
import Testing

@testable import SumikaApp

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

    #expect(state.htmlPreview?.relativePath == WorkspaceRelativePath(rawValue: "index.html"))
    #expect(state.filePreview == nil)
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

    #expect(state.htmlPreview == nil)
    #expect(state.filePreview?.relativePath == WorkspaceRelativePath(rawValue: "notes.txt"))
    #expect(state.isVisible)
    #expect(state.errorMessage == nil)
  }

  @Test
  func closeMethodsClearOnlyTheirPreviewKind() throws {
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
    state.closeFilePreview()

    #expect(state.htmlPreview != nil)
    #expect(state.filePreview == nil)

    state.closeHTMLPreview()
    #expect(!state.isVisible)

    #expect(state.showFilePreview(path: "notes.txt", in: workspace))
    state.closeHTMLPreview()
    #expect(state.htmlPreview == nil)
    #expect(state.filePreview != nil)

    state.closeFilePreview()
    #expect(!state.isVisible)
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
    let rootURL = FileManager.default.temporaryDirectory.appending(
      path: "sumika-workspace-preview-test-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    return Workspace(
      name: "Project",
      rootURL: URL(filePath: Workspace.normalizedPath(for: rootURL))
    )
  }
}
