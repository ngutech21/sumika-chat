import Foundation
import Testing

@testable import SumikaCore

@MainActor
private enum ConversationEngineTestModelRegistry {
  private final class WeakModelControllerReference {
    weak var controller: ModelRuntimeController?

    init(_ controller: ModelRuntimeController) {
      self.controller = controller
    }
  }

  private static var controllers: [ObjectIdentifier: WeakModelControllerReference] = [:]

  static func register(
    _ modelController: ModelRuntimeController,
    for conversationEngine: ConversationEngine
  ) {
    controllers = controllers.filter { $0.value.controller != nil }
    controllers[ObjectIdentifier(conversationEngine)] =
      WeakModelControllerReference(modelController)
  }

  static func modelController(
    for conversationEngine: ConversationEngine
  ) -> ModelRuntimeController {
    guard let controller = controllers[ObjectIdentifier(conversationEngine)]?.controller else {
      preconditionFailure("Missing model controller for ConversationEngine test composition")
    }
    return controller
  }
}

@MainActor
extension ConversationEngine {
  var modelRuntime: ModelRuntimeController {
    ConversationEngineTestModelRegistry.modelController(for: self)
  }

  convenience init(
    runtime: any ChatModelRuntime,
    resourceMonitor: any ProcessResourceMonitoring = ProcessResourceMonitor(),
    modelPath: String,
    modelSettingsStore: any ModelSettingsStoring = ModelSettingsStore(),
    modelDownloader: any ModelDownloading = UnavailableModelDownloader(),
    modelAvailability: @escaping @Sendable (ManagedModel) -> Bool =
      ModelLifecycleCoordinator.defaultModelAvailability,
    toolOrchestrator: ToolOrchestrator = ToolOrchestrator(executorRegistry: .codingAgent),
    chatAttachmentLoader: any ChatAttachmentLoading = ChatAttachmentLoader(),
    turnTracer: any TurnTracing = NoopTurnTracer(),
    chatSession: ChatSession = ChatSession(),
    workspaceInstructionsLoader: (any WorkspaceInstructionsLoading)? = nil
  ) {
    self.init(
      testSelectedModelID: chatSession.selectedModelID,
      modelPath: modelPath,
      modelContextTokenLimit: ManagedModelCatalog.defaultModel.defaultContextTokenLimit,
      chatSession: chatSession,
      modelSettingsStore: modelSettingsStore,
      modelDownloader: modelDownloader,
      runtime: runtime,
      resourceMonitor: resourceMonitor,
      modelAvailability: modelAvailability,
      toolOrchestrator: toolOrchestrator,
      chatAttachmentLoader: chatAttachmentLoader,
      turnTracer: turnTracer
    )
    if let workspaceInstructionsLoader {
      self.workspaceInstructionsLoader = workspaceInstructionsLoader
    }
  }

  private convenience init(
    testSelectedModelID selectedModelID: ManagedModel.ID,
    modelPath: String,
    modelContextTokenLimit: Int,
    chatSession: ChatSession,
    modelSettingsStore: any ModelSettingsStoring,
    modelDownloader: any ModelDownloading,
    runtime: any ChatModelRuntime,
    resourceMonitor: any ProcessResourceMonitoring,
    modelAvailability: @escaping @Sendable (ManagedModel) -> Bool,
    toolOrchestrator: ToolOrchestrator,
    chatAttachmentLoader: any ChatAttachmentLoading,
    turnTracer: any TurnTracing
  ) {
    let operationID = UUID()
    let runtimeOperations = RuntimeOperationCoordinator(
      runtime: runtime,
      initialOperationID: operationID
    )
    let modelLifecycleCoordinator = ModelLifecycleCoordinator(
      modelDownloader: modelDownloader,
      runtimeOperations: runtimeOperations,
      modelAvailability: modelAvailability
    )
    let modelController = ModelRuntimeController(
      selectedModelID: selectedModelID,
      modelPath: modelPath,
      modelContextTokenLimit: modelContextTokenLimit,
      modelSettingsStore: modelSettingsStore,
      runtimeOperations: runtimeOperations,
      modelLifecycleCoordinator: modelLifecycleCoordinator,
      resourceMonitor: resourceMonitor,
      initialOperationID: operationID
    )
    self.init(
      conversationModel: { [modelController] in
        modelController.conversationState
      },
      runtimeContextClearCoordinator: RuntimeContextClearCoordinator(
        modelLifecycleCoordinator: modelLifecycleCoordinator
      ),
      chatGenerationCoordinator: ChatGenerationCoordinator(
        runtimeOperations: runtimeOperations,
        turnTracer: turnTracer
      ),
      toolOrchestrator: toolOrchestrator,
      chatAttachmentLoader: chatAttachmentLoader,
      turnTracer: turnTracer
    )
    installConversation(
      chatSession,
      in: Workspace(
        name: "Test Workspace",
        rootURL: FileManager.default.temporaryDirectory,
        sessions: [chatSession]
      ),
      modelRuntimeWasReset: false,
      prepareRuntimeContext: false
    )
    ConversationEngineTestModelRegistry.register(modelController, for: self)
    modelController.setEventHandlers(
      modelManagementEventHandlers(errorDidOccur: { _ in })
    )
  }

  func loadSession(_ session: ChatSession) {
    let workspace = Workspace(
      name: "Test Workspace",
      rootURL: FileManager.default.temporaryDirectory,
      sessions: [session]
    )
    let model =
      ManagedModelCatalog.model(id: session.selectedModelID)
      ?? ManagedModelCatalog.defaultModel
    let didResetModelRuntime = modelRuntime.applySessionModel(model)
    installConversation(
      session,
      in: workspace,
      modelRuntimeWasReset: didResetModelRuntime
    )
  }

  func loadSession(
    from workspace: Workspace,
    sessionID: ChatSession.ID
  ) throws {
    if activeSessionID == sessionID {
      updateActiveWorkspace(workspace)
      return
    }
    let session = try #require(workspace.sessions.first { $0.id == sessionID })
    let model =
      ManagedModelCatalog.model(id: session.selectedModelID)
      ?? ManagedModelCatalog.defaultModel
    let didResetModelRuntime = modelRuntime.applySessionModel(model)
    installConversation(
      session,
      in: workspace,
      modelRuntimeWasReset: didResetModelRuntime
    )
  }

  @discardableResult
  func sendMessageInTestWorkspace(prompt: String) throws -> Bool {
    try sendMessage(prompt: prompt)
    return true
  }
}

func makeConversationTestWorkspace(containing session: ChatSession) throws -> Workspace {
  let rootURL = FileManager.default.temporaryDirectory.appending(
    path: "sumika-conversation-tests-\(UUID().uuidString)",
    directoryHint: .isDirectory
  )
  try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
  return Workspace(
    name: "Test Workspace",
    rootURL: rootURL,
    sessions: [session]
  )
}

actor NonCooperativeStreamingRuntime: ChatModelRuntime {
  private let chunks: [String]
  private var streamContinuation: CheckedContinuation<Void, Never>?
  private var didReleaseChunks = false
  private(set) var didStartStreaming = false
  private(set) var didFinishStreaming = false

  init(chunks: [String]) {
    self.chunks = chunks
  }

  func load(configuration: ChatModelConfiguration) async throws {}
  func unload() async {}
  func clearContext() async {}

  func releaseChunks() {
    didReleaseChunks = true
    if let streamContinuation {
      streamContinuation.resume()
      self.streamContinuation = nil
    }
  }

  func streamReply(
    for transcript: ModelPromptProjection,
    attachments: [ChatAttachment],
    promptPlan: ChatRuntimePromptPlan,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = transcript
    _ = attachments
    _ = promptPlan
    _ = settings

    didStartStreaming = true
    return AsyncThrowingStream { continuation in
      Task.detached { [chunks] in
        await withCheckedContinuation { release in
          Task {
            await self.storeStreamContinuation(release)
          }
        }

        for chunk in chunks {
          continuation.yield(.chunk(chunk))
        }
        continuation.yield(.completed(nil))
        continuation.finish()
        await self.recordStreamFinished()
      }
    }
  }

  private func storeStreamContinuation(_ continuation: CheckedContinuation<Void, Never>) {
    if didReleaseChunks {
      continuation.resume()
      return
    }
    streamContinuation = continuation
    Task {
      try? await Task.sleep(for: .seconds(2))
      self.releaseChunks()
    }
  }

  private func recordStreamFinished() {
    didFinishStreaming = true
  }
}

actor ControlledContextUsageRuntime: ChatModelRuntime {
  func load(configuration: ChatModelConfiguration) async throws {
    _ = configuration
  }

  func unload() async {}
  func clearContext() async {}

  func streamReply(
    for transcript: ModelPromptProjection,
    attachments: [ChatAttachment],
    promptPlan: ChatRuntimePromptPlan,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = transcript
    _ = attachments
    _ = promptPlan
    _ = settings
    return AsyncThrowingStream { continuation in
      continuation.finish()
    }
  }
}

actor CountingClearContextRuntime: ChatModelRuntime {
  private(set) var clearContextCount = 0

  func load(configuration: ChatModelConfiguration) async throws {
    _ = configuration
  }

  func unload() async {}

  func clearContext() async {
    clearContextCount += 1
  }

  func streamReply(
    for transcript: ModelPromptProjection,
    attachments: [ChatAttachment],
    promptPlan: ChatRuntimePromptPlan,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = transcript
    _ = attachments
    _ = promptPlan
    _ = settings
    return AsyncThrowingStream { continuation in
      continuation.yield(.completed(nil))
      continuation.finish()
    }
  }
}

actor InterruptedStreamingRuntime: ChatModelRuntime {
  private let chunks: [String]

  init(chunks: [String] = []) {
    self.chunks = chunks
  }

  func load(configuration: ChatModelConfiguration) async throws {
    _ = configuration
  }

  func unload() async {}

  func clearContext() async {}

  func streamReply(
    for transcript: ModelPromptProjection,
    attachments: [ChatAttachment],
    promptPlan: ChatRuntimePromptPlan,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = transcript
    _ = attachments
    _ = promptPlan
    _ = settings
    return AsyncThrowingStream { continuation in
      for chunk in chunks {
        continuation.yield(.chunk(chunk))
      }
      continuation.finish()
    }
  }
}

actor ControlledStreamingRuntime: ChatModelRuntime {
  private let turns: [[ChatModelStreamEvent]]
  private let blockedCallIndexes: Set<Int>
  private var streamContinuations: [Int: CheckedContinuation<Void, Never>] = [:]
  private var releasedCallIndexes: Set<Int> = []
  private var streamReplyCount = 0
  private(set) var completedCallIndexes: Set<Int> = []
  private(set) var capturedMessages: [[ProjectedModelContextEntry]] = []
  private(set) var capturedSystemPrompts: [String] = []
  private(set) var capturedToolContexts: [ChatRuntimeToolContext?] = []
  private(set) var capturedPromptPlans: [ChatRuntimePromptPlan] = []

  init(turns: [[String]], blockedCallIndexes: Set<Int>) {
    self.turns = turns.map { $0.map(ChatModelStreamEvent.chunk) }
    self.blockedCallIndexes = blockedCallIndexes
  }

  init(eventTurns: [[ChatModelStreamEvent]], blockedCallIndexes: Set<Int>) {
    self.turns = eventTurns
    self.blockedCallIndexes = blockedCallIndexes
  }

  var startedStreamCount: Int {
    streamReplyCount
  }

  func load(configuration: ChatModelConfiguration) async throws {
    _ = configuration
  }

  func unload() async {}
  func clearContext() async {}

  func streamReply(
    for transcript: ModelPromptProjection,
    attachments: [ChatAttachment],
    promptPlan: ChatRuntimePromptPlan,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = attachments
    _ = settings

    capturedPromptPlans.append(promptPlan)
    capturedToolContexts.append(promptPlan.toolContext)
    capturedMessages.append(
      transcript.projectedEntries(mode: .fullHistory))
    capturedSystemPrompts.append(promptPlan.stableInstructions)
    let callIndex = streamReplyCount
    streamReplyCount += 1
    let events = turns[min(callIndex, turns.count - 1)]
    let shouldBlock = blockedCallIndexes.contains(callIndex)

    return AsyncThrowingStream { continuation in
      let task = Task {
        if shouldBlock {
          await withCheckedContinuation { release in
            Task {
              self.storeStreamContinuation(release, callIndex: callIndex)
            }
          }
        }

        guard !Task.isCancelled else {
          continuation.finish(throwing: CancellationError())
          self.recordStreamFinished(callIndex: callIndex)
          return
        }

        for event in events {
          continuation.yield(event)
        }
        continuation.yield(
          .completed(
            ChatGenerationMetrics(
              generatedTokenCount: events.count,
              tokensPerSecond: 100,
              durationMs: Double(events.count) * 10
            )
          )
        )
        continuation.finish()
        self.recordStreamFinished(callIndex: callIndex)
      }

      continuation.onTermination = { _ in
        task.cancel()
      }
    }
  }

  func releaseStream(callIndex: Int) {
    releasedCallIndexes.insert(callIndex)
    streamContinuations.removeValue(forKey: callIndex)?.resume()
  }

  private func storeStreamContinuation(
    _ continuation: CheckedContinuation<Void, Never>,
    callIndex: Int
  ) {
    guard !releasedCallIndexes.contains(callIndex) else {
      continuation.resume()
      return
    }
    streamContinuations[callIndex] = continuation
    Task {
      try? await Task.sleep(for: .seconds(2))
      self.releaseStream(callIndex: callIndex)
    }
  }

  private func recordStreamFinished(callIndex: Int) {
    completedCallIndexes.insert(callIndex)
  }
}

actor PartialFailingStreamingRuntime: ChatModelRuntime {
  private let chunks: [String]

  init(chunks: [String]) {
    self.chunks = chunks
  }

  func load(configuration: ChatModelConfiguration) async throws {
    _ = configuration
  }

  func unload() async {}
  func clearContext() async {}

  func streamReply(
    for transcript: ModelPromptProjection,
    attachments: [ChatAttachment],
    promptPlan: ChatRuntimePromptPlan,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = transcript
    _ = attachments
    _ = promptPlan
    _ = settings

    return AsyncThrowingStream { continuation in
      for chunk in chunks {
        continuation.yield(.chunk(chunk))
      }
      continuation.finish(throwing: ChatSessionFakeChatModelRuntimeError.streamFailed)
    }
  }
}

actor DelayedClearContextRuntime: ChatModelRuntime {
  private var clearContextContinuation: CheckedContinuation<Void, Never>?
  private(set) var didStartClearContext = false
  private(set) var didFinishClearContext = false
  private(set) var streamReplyCount = 0

  func load(configuration: ChatModelConfiguration) async throws {
    _ = configuration
  }

  func unload() async {}

  func clearContext() async {
    didStartClearContext = true
    await withCheckedContinuation { continuation in
      clearContextContinuation = continuation
      Task {
        try? await Task.sleep(for: .seconds(2))
        self.releaseClearContext()
      }
    }
    didFinishClearContext = true
  }

  func releaseClearContext() {
    clearContextContinuation?.resume()
    clearContextContinuation = nil
  }

  func streamReply(
    for transcript: ModelPromptProjection,
    attachments: [ChatAttachment],
    promptPlan: ChatRuntimePromptPlan,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = transcript
    _ = attachments
    _ = promptPlan
    _ = settings
    streamReplyCount += 1
    return AsyncThrowingStream { continuation in
      continuation.yield(.completed(nil))
      continuation.finish()
    }
  }
}

final class BlockingFirstAttachmentLoader: ChatAttachmentLoading, @unchecked Sendable {
  private let lock = NSLock()
  private let firstLoadRelease = DispatchSemaphore(value: 0)
  private var _startedCount = 0
  private var _completedCount = 0

  var startedCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return _startedCount
  }

  var completedCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return _completedCount
  }

  func loadAttachments(
    from urls: [URL],
    existingAttachments: [ChatAttachment]
  ) throws -> [ChatAttachment] {
    _ = existingAttachments
    lock.lock()
    _startedCount += 1
    let callNumber = _startedCount
    lock.unlock()

    if callNumber == 1 {
      guard firstLoadRelease.wait(timeout: .now() + .seconds(2)) == .success else {
        throw TestWaitTimeoutError()
      }
    }

    lock.lock()
    _completedCount += 1
    lock.unlock()

    guard let url = urls.first else {
      return []
    }
    return [
      ChatAttachment(
        url: url,
        displayName: url.lastPathComponent,
        kind: .text,
        content: callNumber == 1 ? "first" : "second"
      )
    ]
  }

  func releaseFirstLoad() {
    firstLoadRelease.signal()
  }
}

actor ChatSessionFakeChatModelRuntime: ChatModelRuntime {
  private let turns: [[ChatModelStreamEvent]]
  private let failingStreamReplyCalls: Set<Int>
  private let debugSnapshot: RuntimeCacheDebugSnapshot?
  private let automaticallyCompletes: Bool
  private var streamReplyCount = 0
  private(set) var capturedMessages: [[ProjectedModelContextEntry]] = []
  private(set) var capturedAttachments: [[ChatAttachment]] = []
  private(set) var capturedSystemPrompts: [String] = []
  private(set) var capturedGenerationSettings: [ChatGenerationSettings] = []
  private(set) var capturedToolContexts: [ChatRuntimeToolContext?] = []
  private(set) var capturedPromptPlans: [ChatRuntimePromptPlan] = []

  init(
    chunks: [String] = [],
    debugSnapshot: RuntimeCacheDebugSnapshot? = nil,
    automaticallyCompletes: Bool = true
  ) {
    self.turns = [chunks.map(ChatModelStreamEvent.chunk)]
    self.failingStreamReplyCalls = []
    self.debugSnapshot = debugSnapshot
    self.automaticallyCompletes = automaticallyCompletes
  }

  init(
    eventTurns: [[ChatModelStreamEvent]],
    failingStreamReplyCalls: Set<Int> = [],
    debugSnapshot: RuntimeCacheDebugSnapshot? = nil,
    automaticallyCompletes: Bool = true
  ) {
    self.turns = eventTurns
    self.failingStreamReplyCalls = failingStreamReplyCalls
    self.debugSnapshot = debugSnapshot
    self.automaticallyCompletes = automaticallyCompletes
  }

  func load(configuration: ChatModelConfiguration) async throws {
    _ = configuration
  }

  func unload() async {}

  func clearContext() async {}

  func runtimeCacheDebugSnapshot() async -> RuntimeCacheDebugSnapshot? {
    debugSnapshot
  }

  func streamReply(
    for transcript: ModelPromptProjection,
    attachments: [ChatAttachment],
    promptPlan: ChatRuntimePromptPlan,
    settings: ChatGenerationSettings
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    capturedPromptPlans.append(promptPlan)
    capturedToolContexts.append(promptPlan.toolContext)
    capturedMessages.append(
      transcript.projectedEntries(mode: .fullHistory))
    capturedAttachments.append(attachments)
    capturedSystemPrompts.append(promptPlan.stableInstructions)
    capturedGenerationSettings.append(settings)
    let callIndex = streamReplyCount
    let events = turns[min(callIndex, turns.count - 1)]
    streamReplyCount += 1

    if failingStreamReplyCalls.contains(callIndex) {
      return AsyncThrowingStream { continuation in
        continuation.finish(throwing: ChatSessionFakeChatModelRuntimeError.streamFailed)
      }
    }

    return AsyncThrowingStream { continuation in
      for event in events {
        continuation.yield(event)
      }
      if automaticallyCompletes {
        continuation.yield(
          .completed(
            ChatGenerationMetrics(
              generatedTokenCount: events.count,
              tokensPerSecond: 100,
              durationMs: Double(events.count) * 10
            )
          )
        )
      }
      continuation.finish()
    }
  }

}

enum ChatSessionFakeChatModelRuntimeError: Error {
  case streamFailed
}
