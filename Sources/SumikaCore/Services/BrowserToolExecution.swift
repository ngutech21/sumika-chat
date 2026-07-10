public protocol BrowserToolServing: Sendable {
  func refresh(_ input: BrowserRefreshInput) async -> BrowserRefreshResult
  func inspect(_ input: BrowserInspectInput) async -> BrowserInspectResult
}

public struct UnavailableBrowserToolService: BrowserToolServing {
  public init() {}

  public func refresh(_ input: BrowserRefreshInput) async -> BrowserRefreshResult {
    _ = input
    return .failed(reason: .executionError(Self.unavailableMessage))
  }

  public func inspect(_ input: BrowserInspectInput) async -> BrowserInspectResult {
    _ = input
    return .failed(reason: .executionError(Self.unavailableMessage))
  }

  public static let unavailableMessage =
    "HTML preview is not available. Open a preview with /preview <path-to-html-file> first."
}
