import Foundation

/// Agent-owned inputs for composing the effective tool registry of a turn.
/// The application supplies settings and connected MCP contributions; Agent
/// owns built-in membership, selection filtering, and duplicate handling.
struct AgentToolConfiguration: Sendable {
  let todoWriteEnabled: Bool
  let mcpExecutorGroups: [MCPAgentToolExecutorGroup]

  func executorRegistry(selectedMCPServerIDs: [UUID]) -> ToolExecutorRegistry {
    let selectedIDs = Set(selectedMCPServerIDs)
    let mcpExecutors =
      mcpExecutorGroups
      .filter { selectedIDs.contains($0.serverID) }
      .flatMap(\.executors)
    return ToolExecutorRegistry.codingAgentRegistry(
      todoWriteEnabled: todoWriteEnabled
    )
    .merging(mcpExecutors)
  }
}

extension ToolExecutorRegistry {
  private static func codingAgentExecutors(todoWriteEnabled: Bool) -> [AnyToolExecutor] {
    var executors = [
      AnyToolExecutor(ReadFileToolExecutor()),
      AnyToolExecutor(ShowFileToolExecutor()),
      AnyToolExecutor(ListFilesToolExecutor()),
      AnyToolExecutor(GlobFilesToolExecutor()),
      AnyToolExecutor(SearchFilesToolExecutor()),
      AnyToolExecutor(WorkspaceDiffToolExecutor()),
      AnyToolExecutor(WorkspaceDiagnosticsToolExecutor()),
      AnyToolExecutor(BrowserRefreshToolExecutor()),
      AnyToolExecutor(BrowserInspectToolExecutor()),
      AnyToolExecutor(EditFileToolExecutor()),
      AnyToolExecutor(WriteFileToolExecutor()),
      AnyToolExecutor(RunCommandToolExecutor()),
    ]
    if todoWriteEnabled {
      executors.append(AnyToolExecutor(TodoWriteToolExecutor()))
    }
    executors.append(contentsOf: [
      AnyToolExecutor(AskUserToolExecutor()),
      AnyToolExecutor(FinishTaskToolExecutor()),
      AnyToolExecutor(WebSearchToolExecutor()),
      AnyToolExecutor(WebFetchToolExecutor()),
    ])
    return executors
  }

  static let codingAgent = codingAgentRegistry(todoWriteEnabled: true)

  static func codingAgentRegistry(todoWriteEnabled: Bool) -> ToolExecutorRegistry {
    ToolExecutorRegistry(codingAgentExecutors(todoWriteEnabled: todoWriteEnabled))
  }
}

extension ToolOrchestrator {
  package static func agent(
    todoWriteEnabled: Bool,
    browserToolService: any BrowserToolServing = UnavailableBrowserToolService(),
    webAccessSettingsProvider: @escaping @Sendable () async -> WebAccessSettings = {
      .disabled
    }
  ) -> ToolOrchestrator {
    ToolOrchestrator(
      executorRegistry: .codingAgentRegistry(todoWriteEnabled: todoWriteEnabled),
      browserToolService: browserToolService,
      webAccessSettingsProvider: webAccessSettingsProvider
    )
  }
}
