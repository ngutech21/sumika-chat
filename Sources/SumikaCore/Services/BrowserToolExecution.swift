package protocol BrowserToolServing: Sendable {
  func refresh(_ input: BrowserRefreshInput) async -> BrowserRefreshResult
  func inspect(_ input: BrowserInspectInput) async -> BrowserInspectResult
}

package struct UnavailableBrowserToolService: BrowserToolServing {
  package init() {}

  package func refresh(_ input: BrowserRefreshInput) async -> BrowserRefreshResult {
    _ = input
    return .failed(reason: .executionError(Self.unavailableMessage))
  }

  package func inspect(_ input: BrowserInspectInput) async -> BrowserInspectResult {
    _ = input
    return .failed(reason: .executionError(Self.unavailableMessage))
  }

  package static let unavailableMessage =
    "HTML preview is not available. Open a preview with /preview <path-to-html-file> first."
}
