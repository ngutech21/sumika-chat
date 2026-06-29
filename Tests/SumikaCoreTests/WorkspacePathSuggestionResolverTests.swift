import Foundation
import Testing

@testable import SumikaCore

struct WorkspacePathSuggestionResolverTests {
  @Test
  func suggestsSimilarBasenameAndExtension() throws {
    let workspace = try makeWorkspace()
    try write("html", to: "index.html", in: workspace)
    try write("swift", to: "Sources/ToolLoopCoordinator.swift", in: workspace)

    let htmlSuggestions = WorkspacePathSuggestionResolver().suggestions(
      forMissingPath: "landing.html",
      workspace: workspace
    )
    let swiftSuggestions = WorkspacePathSuggestionResolver().suggestions(
      forMissingPath: "Sources/ToolLoop.swift",
      workspace: workspace
    )

    #expect(htmlSuggestions.first?.path == WorkspaceRelativePath(rawValue: "index.html"))
    #expect(htmlSuggestions.first?.reason.contains("same extension") == true)
    #expect(
      swiftSuggestions.first?.path
        == WorkspaceRelativePath(rawValue: "Sources/ToolLoopCoordinator.swift")
    )
    #expect(swiftSuggestions.first?.reason.contains("same directory") == true)
    #expect(swiftSuggestions.first?.reason.contains("similar basename") == true)
  }

  @Test
  func ranksSameDirectoryBeforeDistantExtensionMatch() throws {
    let workspace = try makeWorkspace()
    try write("near", to: "Sources/AppView.swift", in: workspace)
    try write("far", to: "Tests/AppView.swift", in: workspace)

    let suggestions = WorkspacePathSuggestionResolver().suggestions(
      forMissingPath: "Sources/App.swift",
      workspace: workspace
    )

    #expect(suggestions.first?.path == WorkspaceRelativePath(rawValue: "Sources/AppView.swift"))
  }

  @Test
  func ignoresNoiseDirectoriesAndLimitsStableResults() throws {
    let workspace = try makeWorkspace()
    try write("ignored", to: ".git/hooks/page.html", in: workspace)
    try write("ignored", to: "node_modules/pkg/page.html", in: workspace)
    try write("1", to: "A/page.html", in: workspace)
    try write("2", to: "B/page.html", in: workspace)
    try write("3", to: "C/page.html", in: workspace)
    try write("4", to: "D/page.html", in: workspace)
    try write("5", to: "E/page.html", in: workspace)
    try write("6", to: "F/page.html", in: workspace)

    let suggestions = WorkspacePathSuggestionResolver().suggestions(
      forMissingPath: "page.html",
      workspace: workspace,
      maxSuggestions: 5
    )

    #expect(
      suggestions.map(\.path.rawValue) == [
        "A/page.html",
        "B/page.html",
        "C/page.html",
        "D/page.html",
        "E/page.html",
      ])
  }

  private func makeWorkspace() throws -> Workspace {
    let rootURL = FileManager.default.temporaryDirectory
      .appending(path: "sumika-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
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
