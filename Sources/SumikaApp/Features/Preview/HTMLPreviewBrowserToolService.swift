import SumikaCore

actor HTMLPreviewBrowserToolService {
  typealias RefreshHandler =
    @MainActor @Sendable (BrowserRefreshInput) async -> BrowserRefreshResult
  typealias InspectHandler =
    @MainActor @Sendable (BrowserInspectInput) async -> BrowserInspectResult

  private var refreshHandler: RefreshHandler?
  private var inspectHandler: InspectHandler?

  func register(
    refreshHandler: @escaping RefreshHandler,
    inspectHandler: @escaping InspectHandler
  ) {
    self.refreshHandler = refreshHandler
    self.inspectHandler = inspectHandler
  }

  func clear() {
    refreshHandler = nil
    inspectHandler = nil
  }
}

extension HTMLPreviewBrowserToolService: BrowserToolServing {
  func refresh(_ input: BrowserRefreshInput) async -> BrowserRefreshResult {
    guard let refreshHandler else {
      return .failed(reason: .executionError(UnavailableBrowserToolService.unavailableMessage))
    }
    return await refreshHandler(input)
  }

  func inspect(_ input: BrowserInspectInput) async -> BrowserInspectResult {
    guard let inspectHandler else {
      return .failed(reason: .executionError(UnavailableBrowserToolService.unavailableMessage))
    }
    return await inspectHandler(input)
  }
}
