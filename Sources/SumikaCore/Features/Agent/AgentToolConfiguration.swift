import Foundation

/// Agent-owned inputs for composing the effective tool registry of a turn.
/// The application supplies settings and connected MCP contributions; Agent
/// owns built-in membership, selection filtering, and duplicate handling.
struct AgentToolConfiguration: Sendable {
  var documentMarkdownConverter: (any DocumentMarkdownConverting)?
  let todoWriteEnabled: Bool
  let mcpExecutorGroups: [MCPAgentToolExecutorGroup]

  func executorRegistry(selectedMCPServerIDs: [UUID]) -> ToolExecutorRegistry {
    let selectedIDs = Set(selectedMCPServerIDs)
    let mcpExecutors =
      mcpExecutorGroups
      .filter { selectedIDs.contains($0.serverID) }
      .flatMap(\.executors)
      .filter { $0.definition.name != .readSkillResource }
    return ToolExecutorRegistry.codingAgentRegistry(
      todoWriteEnabled: todoWriteEnabled,
      documentMarkdownConverter: documentMarkdownConverter
    )
    .merging(mcpExecutors)
  }
}

extension ToolExecutorRegistry {
  private static func codingAgentExecutors(
    todoWriteEnabled: Bool, documentMarkdownConverter: (any DocumentMarkdownConverting)?
  ) -> [AnyToolExecutor] {
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
    if let documentMarkdownConverter {
      executors.insert(
        AnyToolExecutor(ReadDocumentToolExecutor(converter: documentMarkdownConverter)), at: 1)
    }
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

  // Test-only canonical registry; exercised through @testable import.
  // swiftlint:disable:next unused_declaration
  static let codingAgent = codingAgentRegistry(todoWriteEnabled: true)

  static func codingAgentRegistry(
    todoWriteEnabled: Bool, documentMarkdownConverter: (any DocumentMarkdownConverting)? = nil
  ) -> ToolExecutorRegistry {
    ToolExecutorRegistry(
      codingAgentExecutors(
        todoWriteEnabled: todoWriteEnabled, documentMarkdownConverter: documentMarkdownConverter
      ))
  }
}

extension ToolOrchestrator {
  static func agent(
    todoWriteEnabled: Bool,
    documentMarkdownConverter: (any DocumentMarkdownConverting)? = nil,
    browserToolService: any BrowserToolServing = UnavailableBrowserToolService(),
    webAccessSettingsProvider: @escaping @Sendable () async -> WebAccessSettings = {
      .disabled
    }
  ) -> ToolOrchestrator {
    ToolOrchestrator(
      executorRegistry: .codingAgentRegistry(
        todoWriteEnabled: todoWriteEnabled, documentMarkdownConverter: documentMarkdownConverter
      ),
      browserToolService: browserToolService,
      webAccessSettingsProvider: webAccessSettingsProvider
    )
  }
}
