import Foundation
import LocalCoderCore
import Testing

@testable import local_coder

struct HTMLPreviewResolverTests {
  @Test
  func resolvesHTMLFilesInsideWorkspace() throws {
    let workspace = try makeWorkspace()
    let htmlURL = workspace.rootURL.appending(path: "index.HTML", directoryHint: .notDirectory)
    try "<!doctype html>".write(to: htmlURL, atomically: true, encoding: .utf8)

    let preview = try HTMLPreviewResolver().resolve(path: "index.HTML", in: workspace)

    #expect(preview.url == htmlURL)
    #expect(preview.relativePath == WorkspaceRelativePath(rawValue: "index.HTML"))
    #expect(preview.readAccessRootURL == workspace.rootURL)
  }

  @Test
  func rejectsNonHTMLFiles() throws {
    let workspace = try makeWorkspace()
    try "notes".write(
      to: workspace.rootURL.appending(path: "notes.txt", directoryHint: .notDirectory),
      atomically: true,
      encoding: .utf8
    )

    #expect(throws: HTMLPreviewResolutionError.unsupportedFileType("notes.txt")) {
      try HTMLPreviewResolver().resolve(path: "notes.txt", in: workspace)
    }
  }

  @Test
  func rejectsPathsOutsideWorkspace() throws {
    let workspace = try makeWorkspace()

    #expect(throws: WorkspacePathResolutionError.pathOutsideWorkspace) {
      try HTMLPreviewResolver().resolve(path: "../index.html", in: workspace)
    }
  }

  private func makeWorkspace() throws -> Workspace {
    let rootURL = FileManager.default.temporaryDirectory.appending(
      path: "local-coder-html-preview-test-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    return Workspace(
      name: "Project", rootURL: URL(filePath: Workspace.normalizedPath(for: rootURL)))
  }
}
