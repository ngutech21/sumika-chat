/// An alternate workspace execution boundary. SumikaEval supplies Harbor-backed I/O.
package struct WorkspaceExecution: Sendable {
  let fileIO: any WorkspaceFileIO
  let commandRunner: any CommandProcessRunning
  private let webClient: (any WebHTTPClient & WebHostResolving)?

  package init(
    fileIO: any WorkspaceFileIO, commandRunner: any CommandProcessRunning,
    webClient: (any WebHTTPClient & WebHostResolving)? = nil
  ) {
    self.fileIO = fileIO
    self.commandRunner = commandRunner
    self.webClient = webClient
  }

  var webAccessSettings: WebAccessSettings {
    WebAccessSettings(policy: webClient == nil ? .off : .allow)
  }

  var webSearcher: any WebSearching {
    guard let webClient else { return DefaultWebSearchService() }
    return DefaultWebSearchService(httpClient: webClient, hostResolver: webClient)
  }

  var webFetcher: any WebFetching {
    guard let webClient else { return DefaultWebFetchService() }
    return DefaultWebFetchService(httpClient: webClient, hostResolver: webClient)
  }

  var executorRegistry: ToolExecutorRegistry {
    var executors = [
      AnyToolExecutor(ReadFileToolExecutor()),
      AnyToolExecutor(EditFileToolExecutor()),
      AnyToolExecutor(WriteFileToolExecutor()),
      AnyToolExecutor(
        RunCommandToolExecutor(
          environment: [:], pathPrefixDirectories: [], processRunner: commandRunner)),
      AnyToolExecutor(AskUserToolExecutor()),
      AnyToolExecutor(FinishTaskToolExecutor()),
    ]
    if webClient != nil {
      executors.append(contentsOf: [
        AnyToolExecutor(WebSearchToolExecutor()), AnyToolExecutor(WebFetchToolExecutor()),
      ])
    }
    return ToolExecutorRegistry(executors)
  }
}
