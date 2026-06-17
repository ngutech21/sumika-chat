import Foundation
import Testing

@testable import SumikaCore

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
  func toolNameKeepsRawValueStable() {
    #expect(ToolName(rawValue: "READ-FILE").rawValue == "READ-FILE")
    #expect(ToolName(rawValue: "run command").rawValue == "run command")
  }

  @Test
  func toolNameCodablePreservesRawValue() throws {
    let data = try JSONEncoder().encode(ToolName(rawValue: "READ-FILE"))
    let encoded = try #require(String(data: data, encoding: .utf8))
    let decoded = try JSONDecoder().decode(ToolName.self, from: Data(#""write-file""#.utf8))

    #expect(encoded == #""READ-FILE""#)
    #expect(decoded == ToolName(rawValue: "write-file"))
  }

  private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "sumika-chat-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return URL(filePath: Workspace.normalizedPath(for: url))
  }
}
