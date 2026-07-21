import Foundation

/// Package composition root for Sumika's domain features.
///
/// Callers inject platform and vendor adapters here. The technical runtime,
/// lifecycle, tool, and model coordinators remain implementation details of Core.
@MainActor
package final class Sumika {
  package struct Configuration: Sendable {
    let initialModel: ManagedModel
    let modelPath: String
    let initialModelSettings: StoredModelSettings

    package init(
      initialModel: ManagedModel? = nil,
      modelPath: String? = nil,
      initialModelSettings: StoredModelSettings? = nil
    ) {
      let model =
        initialModel
        ?? ManagedModelCatalog.defaultModel
      let settings =
        initialModelSettings
        ?? StoredModelSettings(
          modeSettings: model.defaultModeSettings,
          contextTokenLimit: model.defaultContextTokenLimit
        )
      self.initialModel = model
      self.modelPath = modelPath ?? model.localPath
      self.initialModelSettings = settings
    }
  }

  package struct Dependencies: Sendable {
    let runtime: any ChatModelRuntime
    let modelSettingsStore: any ModelSettingsStoring
    let modelDownloader: any ModelDownloading
    let resourceMonitor: any ProcessResourceMonitoring
    let modelAvailability: @Sendable (ManagedModel) -> Bool
    let browserToolService: any BrowserToolServing
    let webAccessSettingsProvider: @Sendable () async -> WebAccessSettings
    let chatAttachmentLoader: any ChatAttachmentLoading
    let turnTracer: any TurnTracing

    package init(
      runtime: any ChatModelRuntime,
      modelSettingsStore: any ModelSettingsStoring = ModelSettingsStore(),
      modelDownloader: any ModelDownloading = UnavailableModelDownloader(),
      resourceMonitor: any ProcessResourceMonitoring = ProcessResourceMonitor(),
      modelAvailability: (@Sendable (ManagedModel) -> Bool)? = nil,
      browserToolService: any BrowserToolServing = UnavailableBrowserToolService(),
      webAccessSettingsProvider: @escaping @Sendable () async -> WebAccessSettings = {
        .disabled
      },
      chatAttachmentLoader: any ChatAttachmentLoading = ChatAttachmentLoader(),
      turnTracer: any TurnTracing = NoopTurnTracer()
    ) {
      self.runtime = runtime
      self.modelSettingsStore = modelSettingsStore
      self.modelDownloader = modelDownloader
      self.resourceMonitor = resourceMonitor
      self.modelAvailability =
        modelAvailability ?? ModelLifecycleCoordinator.defaultModelAvailability
      self.browserToolService = browserToolService
      self.webAccessSettingsProvider = webAccessSettingsProvider
      self.chatAttachmentLoader = chatAttachmentLoader
      self.turnTracer = turnTracer
    }
  }

  package let conversation: ConversationFeature
  package let models: ModelManagementFeature
  package let agent: AgentFeature

  package init(
    configuration: Configuration = Configuration(),
    dependencies: Dependencies
  ) {
    let operationID = UUID()
    let runtimeOperations = RuntimeOperationCoordinator(
      runtime: dependencies.runtime,
      initialOperationID: operationID
    )
    let modelLifecycle = ModelLifecycleCoordinator(
      modelDownloader: dependencies.modelDownloader,
      runtimeOperations: runtimeOperations,
      modelAvailability: dependencies.modelAvailability
    )
    let modelController = ModelRuntimeController(
      selectedModelID: configuration.initialModel.id,
      modelPath: configuration.modelPath,
      modelContextTokenLimit: configuration.initialModelSettings.contextTokenLimit,
      selectedModeSettings: configuration.initialModelSettings.modeSettings,
      modelSettingsStore: dependencies.modelSettingsStore,
      runtimeOperations: runtimeOperations,
      modelLifecycleCoordinator: modelLifecycle,
      resourceMonitor: dependencies.resourceMonitor,
      initialOperationID: operationID
    )
    let initialConversationModelState = modelController.conversationState
    let engine = ConversationEngine(
      conversationModel: { [weak modelController] in
        modelController?.conversationState ?? initialConversationModelState
      },
      runtimeContextClearCoordinator: RuntimeContextClearCoordinator(
        modelLifecycleCoordinator: modelLifecycle
      ),
      chatGenerationCoordinator: ChatGenerationCoordinator(
        runtimeOperations: runtimeOperations,
        turnTracer: dependencies.turnTracer
      ),
      toolOrchestrator: ToolOrchestrator.agent(
        todoWriteEnabled: false,
        browserToolService: dependencies.browserToolService,
        webAccessSettingsProvider: dependencies.webAccessSettingsProvider
      ),
      chatAttachmentLoader: dependencies.chatAttachmentLoader,
      workspaceInstructionsLoader: WorkspaceInstructionsLoader(),
      turnTracer: dependencies.turnTracer
    )

    let conversation = ConversationFeature(
      engine: engine,
      sessionCoordinator: ConversationSessionCoordinator(
        modelController: modelController,
        conversationEngine: engine
      )
    )
    let models = ModelManagementFeature(
      modelController: modelController,
      conversationEngine: engine
    )
    let agent = AgentFeature(
      conversationEngine: engine,
      clientManager: MCPClientManager()
    )

    self.conversation = conversation
    self.models = models
    self.agent = agent

    modelController.setEventHandlers(
      engine.modelManagementEventHandlers { [weak models] message in
        models?.handleModelRuntimeError(message)
      }
    )
  }
}
