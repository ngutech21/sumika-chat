import Foundation
import SumikaCore
import Testing

@testable import SumikaApp

struct FilePreviewResolverTests {
  @Test
  func resolvesUTF8FileInsideWorkspace() throws {
    let workspace = try makeWorkspace()
    let fileURL = workspace.rootURL.appending(path: "notes.txt", directoryHint: .notDirectory)
    try "one\ntwo".write(to: fileURL, atomically: true, encoding: .utf8)

    let preview = try FilePreviewResolver().resolve(path: "notes.txt", in: workspace)

    #expect(preview.relativePath == WorkspaceRelativePath(rawValue: "notes.txt"))
    #expect(preview.content == "one\ntwo")
    #expect(preview.lineCount == 2)
    #expect(preview.byteCount == "one\ntwo".utf8.count)
    #expect(!preview.truncated)
  }

  @Test
  func rejectsDirectories() throws {
    let workspace = try makeWorkspace()
    let directoryURL = workspace.rootURL.appending(path: "docs", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

    #expect(throws: FilePreviewResolutionError.notAFile) {
      try FilePreviewResolver().resolve(path: "docs", in: workspace)
    }
  }

  @Test
  func rejectsNonUTF8Files() throws {
    let workspace = try makeWorkspace()
    let fileURL = workspace.rootURL.appending(path: "binary.bin", directoryHint: .notDirectory)
    try Data([0xFF, 0xFE, 0x00]).write(to: fileURL)

    #expect(throws: FilePreviewResolutionError.notUTF8Text("binary.bin")) {
      try FilePreviewResolver().resolve(path: "binary.bin", in: workspace)
    }
  }

  @Test
  func rejectsPathsOutsideWorkspace() throws {
    let workspace = try makeWorkspace()

    #expect(throws: WorkspacePathResolutionError.pathOutsideWorkspace) {
      try FilePreviewResolver().resolve(path: "../notes.txt", in: workspace)
    }
  }

  private func makeWorkspace() throws -> Workspace {
    let rootURL = FileManager.default.temporaryDirectory.appending(
      path: "sumika-file-preview-test-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    return Workspace(
      name: "Project",
      rootURL: URL(filePath: Workspace.normalizedPath(for: rootURL))
    )
  }
}
