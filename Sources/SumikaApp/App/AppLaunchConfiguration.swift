import Foundation
import SumikaCore
import SumikaRuntimeMLX

enum AppLaunchConfiguration {
  static func shouldStartUpdater(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    #if DEBUG
      false
    #else
      shouldStartUpdater(environment: environment, isDebugBuild: false)
    #endif
  }

  // Test-only; exercised through @testable import.
  // swiftlint:disable:next unused_declaration
  static func shouldStartUpdater(
    environment: [String: String],
    isDebugBuild: Bool
  ) -> Bool {
    !isDebugBuild
      && environment["SUMIKA_UI_TEST_MODE"] != "1"
      && !isXcodeUnitTestHost(environment: environment)
  }

  @MainActor
  static func makeAppState(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    runtime: (any ChatModelRuntime)? = nil
  ) -> AppState {
    let debugTraceStore = MLXDebugTraceStore()
    let resolvedRuntime = runtime ?? MLXChatRuntime(debugTraceStore: debugTraceStore)

    if environment["SUMIKA_UI_TEST_MODE"] == "1" {
      return makeUITestAppState(
        environment: environment,
        runtime: resolvedRuntime,
        turnTracer: debugTraceStore
      )
    }

    if isXcodeUnitTestHost(environment: environment) {
      return makeUnitTestHostAppState(
        environment: environment,
        runtime: resolvedRuntime
      )
    }

    return makeConfiguredAppState(
      modelDownloader: HuggingFaceModelDownloader(),
      runtime: resolvedRuntime,
      turnTracer: debugTraceStore
    )
  }

  @MainActor
  private static func makeUITestAppState(
    environment: [String: String],
    runtime: any ChatModelRuntime,
    turnTracer: any TurnTracing
  ) -> AppState {
    let storageRoot = URL(
      filePath: environment["SUMIKA_UI_TEST_STORAGE_ROOT"]
        ?? FileManager.default.temporaryDirectory
        .appending(path: "SumikaUITests", directoryHint: .isDirectory)
        .path(percentEncoded: false),
      directoryHint: .isDirectory
    )
    let workspaceURL = URL(
      filePath: environment["SUMIKA_UI_TEST_WORKSPACE_PATH"]
        ?? storageRoot.appending(path: "workspace", directoryHint: .isDirectory)
        .path(percentEncoded: false),
      directoryHint: .isDirectory
    )
    let modelID = environment["SUMIKA_UI_TEST_MODEL_ID"] ?? ManagedModelCatalog.defaultModelID
    let selectedModel = ManagedModelCatalog.model(id: modelID) ?? ManagedModelCatalog.defaultModel
    let modelSettingsStore = ModelSettingsStore(
      settingsURL: storageRoot.appending(path: "model-settings.json", directoryHint: .notDirectory)
    )
    let webAccessSettingsStore = WebAccessSettingsStore(
      settingsURL: storageRoot.appending(
        path: "web-access-settings.json", directoryHint: .notDirectory)
    )
    let appBehaviorSettingsStore = AppBehaviorSettingsStore(
      settingsURL: storageRoot.appending(
        path: "app-behavior-settings.json", directoryHint: .notDirectory)
    )
    let mcpServersStore = MCPServersStore(
      settingsURL: storageRoot.appending(path: "mcp-servers.json", directoryHint: .notDirectory)
    )
    let workspaceStore = UITestWorkspaceStore(
      baseURL: storageRoot,
      initialLibrary: makeUITestWorkspaceLibrary(
        workspaceURL: workspaceURL,
        selectedModel: selectedModel
      )
    )
    try? FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)

    return makeConfiguredAppState(
      modelDownloader: UnavailableModelDownloader(),
      runtime: runtime,
      turnTracer: turnTracer,
      workspaceStore: workspaceStore,
      modelSettingsStore: modelSettingsStore,
      webAccessSettingsStore: webAccessSettingsStore,
      appBehaviorSettingsStore: appBehaviorSettingsStore,
      mcpServersStore: mcpServersStore
    )
  }

  @MainActor
  private static func makeUnitTestHostAppState(
    environment: [String: String],
    runtime: any ChatModelRuntime
  ) -> AppState {
    let storageRoot = URL(
      filePath: environment["SUMIKA_UNIT_TEST_STORAGE_ROOT"]
        ?? FileManager.default.temporaryDirectory
        .appending(path: "sumika-unit-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        .path(percentEncoded: false),
      directoryHint: .isDirectory
    )

    return makeConfiguredAppState(
      modelDownloader: UnavailableModelDownloader(),
      runtime: runtime,
      modelAvailability: { _ in false },
      turnTracer: NoopTurnTracer(),
      workspaceStore: WorkspaceStore(
        baseURL: storageRoot
      ),
      modelSettingsStore: makeUnitTestHostModelSettingsStore(
        environment: environment,
        storageRoot: storageRoot
      ),
      webAccessSettingsStore: WebAccessSettingsStore(
        settingsURL: storageRoot.appending(
          path: "web-access-settings.json", directoryHint: .notDirectory)
      ),
      appBehaviorSettingsStore: AppBehaviorSettingsStore(
        settingsURL: storageRoot.appending(
          path: "app-behavior-settings.json", directoryHint: .notDirectory)
      ),
      mcpServersStore: MCPServersStore(
        settingsURL: storageRoot.appending(path: "mcp-servers.json", directoryHint: .notDirectory)
      )
    )
  }

  @MainActor
  private static func makeConfiguredAppState(
    modelDownloader: any ModelDownloading,
    runtime: any ChatModelRuntime,
    modelAvailability: @escaping @Sendable (ManagedModel) -> Bool =
      ModelLifecycleCoordinator.defaultModelAvailability,
    turnTracer: any TurnTracing,
    workspaceStore: any WorkspaceStoring = WorkspaceStore(),
    modelSettingsStore: any ModelSettingsStoring = ModelSettingsStore(),
    webAccessSettingsStore: any WebAccessSettingsStoring = WebAccessSettingsStore(),
    appBehaviorSettingsStore: any AppBehaviorSettingsStoring = AppBehaviorSettingsStore(),
    mcpServersStore: any MCPServersStoring = MCPServersStore()
  ) -> AppState {
    let browserToolService = HTMLPreviewBrowserToolService()
    let conversation = makeConversationComposition(
      modelSettingsStore: modelSettingsStore,
      modelDownloader: modelDownloader,
      runtime: runtime,
      modelAvailability: modelAvailability,
      toolOrchestrator: ToolOrchestrator(
        executorRegistry: .codingAgentRegistry(todoWriteEnabled: false),
        browserToolService: browserToolService,
        webAccessSettingsProvider: {
          await webAccessSettingsStore.settings()
        }
      ),
      turnTracer: turnTracer
    )

    return AppState(
      workspaceStore: workspaceStore,
      modelSettingsStore: modelSettingsStore,
      webAccessSettingsStore: webAccessSettingsStore,
      appBehaviorSettingsStore: appBehaviorSettingsStore,
      mcpServersStore: mcpServersStore,
      browserToolService: browserToolService,
      conversation: conversation,
      turnTracer: turnTracer
    )
  }

  @MainActor
  static func makeConversationComposition(
    modelSettingsStore: any ModelSettingsStoring,
    modelDownloader: any ModelDownloading = UnavailableModelDownloader(),
    runtime: any ChatModelRuntime,
    resourceMonitor: any ProcessResourceMonitoring = ProcessResourceMonitor(),
    modelAvailability: @escaping @Sendable (ManagedModel) -> Bool =
      ModelLifecycleCoordinator.defaultModelAvailability,
    toolOrchestrator: ToolOrchestrator,
    chatAttachmentLoader: any ChatAttachmentLoading = ChatAttachmentLoader(),
    turnTracer: any TurnTracing
  ) -> ConversationComposition {
    let selectedModel = ManagedModelCatalog.defaultModel
    let storedSettings = StoredModelSettings(
      modeSettings: selectedModel.defaultModeSettings,
      contextTokenLimit: selectedModel.defaultContextTokenLimit
    )
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
    let modelManagementController = ModelRuntimeController(
      selectedModelID: selectedModel.id,
      modelPath: selectedModel.localPath,
      modelContextTokenLimit: storedSettings.contextTokenLimit,
      modelSettingsStore: modelSettingsStore,
      runtimeOperations: runtimeOperations,
      modelLifecycleCoordinator: modelLifecycleCoordinator,
      resourceMonitor: resourceMonitor,
      initialOperationID: operationID
    )
    let initialConversationState = modelManagementController.conversationState
    let chatController = ChatSessionController(
      conversationModel: { [weak modelManagementController] in
        modelManagementController?.conversationState ?? initialConversationState
      },
      runtimeContextClearCoordinator: RuntimeContextClearCoordinator(
        modelLifecycleCoordinator: modelLifecycleCoordinator
      ),
      chatGenerationCoordinator: ChatGenerationCoordinator(
        runtimeOperations: runtimeOperations,
        turnTracer: turnTracer
      ),
      chatSession: ChatSession(
        turns: [],
        pendingAttachments: [],
        modeSettings: storedSettings.modeSettings
      ),
      toolOrchestrator: toolOrchestrator,
      chatAttachmentLoader: chatAttachmentLoader,
      turnTracer: turnTracer
    )
    let modelManagementState = ModelManagementFeatureState(
      modelController: modelManagementController,
      chatController: chatController
    )
    modelManagementController.setEventHandlers(
      chatController.modelManagementEventHandlers(
        errorDidOccur: { [weak modelManagementState] message in
          modelManagementState?.handleModelRuntimeError(message)
        }
      )
    )
    modelManagementController.loadPersistedModelSelection()
    return ConversationComposition(
      modelManagementState: modelManagementState,
      sessionCoordinator: ConversationSessionCoordinator(
        modelController: modelManagementController,
        chatController: chatController
      ),
      chatController: chatController
    )
  }

  nonisolated private static func makeUnitTestHostModelSettingsStore(
    environment: [String: String],
    storageRoot: URL
  ) -> ModelSettingsStore {
    let userDefaults =
      UserDefaults(
        suiteName: environment["SUMIKA_UNIT_TEST_DEFAULTS_SUITE"]
          ?? "sumika-unit-tests-\(UUID().uuidString)"
      ) ?? .standard

    return ModelSettingsStore(
      userDefaults: userDefaults,
      settingsURL: storageRoot.appending(path: "model-settings.json", directoryHint: .notDirectory)
    )
  }

  private static func isXcodeUnitTestHost(environment: [String: String]) -> Bool {
    environment["XCTestConfigurationFilePath"] != nil
  }

  private static func makeUITestWorkspaceLibrary(
    workspaceURL: URL,
    selectedModel: ManagedModel
  ) -> WorkspaceLibrary {
    let session = ChatSession(
      title: "UI Performance",
      selectedModelID: selectedModel.id,
      modeSettings: selectedModel.defaultModeSettings,
      interactionMode: .chat
    )
    let workspace = Workspace(
      name: workspaceURL.lastPathComponent.isEmpty
        ? "UI Test Workspace" : workspaceURL.lastPathComponent,
      rootURL: workspaceURL,
      sessions: [session]
    )
    return WorkspaceLibrary(
      workspaces: [workspace],
      activeWorkspaceID: workspace.id,
      activeSessionID: session.id
    )
  }
}

struct ConversationComposition {
  let modelManagementState: ModelManagementFeatureState
  let sessionCoordinator: ConversationSessionCoordinator
  let chatController: ChatSessionController
}

private actor UITestWorkspaceStore: WorkspaceStoring {
  private let manifestURL: URL
  private let legacyLibraryURL: URL
  private let backingStore: WorkspaceStore
  private var library: WorkspaceLibrary

  init(baseURL: URL, initialLibrary: WorkspaceLibrary) {
    self.manifestURL =
      baseURL
      .appending(path: "WorkspaceLibrary", directoryHint: .isDirectory)
      .appending(path: "workspaces.json", directoryHint: .notDirectory)
    self.legacyLibraryURL = baseURL.appending(
      path: "workspaces.json",
      directoryHint: .notDirectory
    )
    self.backingStore = WorkspaceStore(baseURL: baseURL)
    self.library = initialLibrary
  }

  func loadLibrary() async -> WorkspaceLibraryLoadResult {
    let hasManifest = FileManager.default.fileExists(
      atPath: manifestURL.path(percentEncoded: false)
    )
    let hasLegacyLibrary = FileManager.default.fileExists(
      atPath: legacyLibraryURL.path(percentEncoded: false)
    )
    guard hasManifest || hasLegacyLibrary else {
      return WorkspaceLibraryLoadResult(library: library)
    }
    let result = await backingStore.loadLibrary()
    if result.canPersist {
      library = result.library
    }
    return result
  }

  func saveLibrary(_ library: WorkspaceLibrary) async throws {
    self.library = library
    try await backingStore.saveLibrary(library)
  }
}
