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
  }

  @MainActor
  static func makeAppState(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    runtime: (any ChatModelRuntime)? = nil
  ) -> AppState {
    let mlxEnvironment = MLXRuntimeComposition.makeChatEnvironment(overriding: runtime)

    if environment["SUMIKA_UI_TEST_MODE"] == "1" {
      return makeUITestAppState(
        environment: environment,
        runtime: mlxEnvironment.runtime,
        turnTracer: mlxEnvironment.turnTracer
      )
    }

    return makeConfiguredAppState(
      modelDownloader: MLXRuntimeComposition.makeModelDownloader(),
      runtime: mlxEnvironment.runtime,
      turnTracer: mlxEnvironment.turnTracer
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
  private static func makeConfiguredAppState(
    modelDownloader: any ModelDownloading,
    runtime: any ChatModelRuntime,
    modelAvailability: (@Sendable (ManagedModel) -> Bool)? = nil,
    turnTracer: any TurnTracing,
    workspaceStore: any WorkspaceStoring = WorkspaceStore(),
    modelSettingsStore: any ModelSettingsStoring = ModelSettingsStore(),
    webAccessSettingsStore: any WebAccessSettingsStoring = WebAccessSettingsStore(),
    appBehaviorSettingsStore: any AppBehaviorSettingsStoring = AppBehaviorSettingsStore(),
    mcpServersStore: any MCPServersStoring = MCPServersStore()
  ) -> AppState {
    let browserToolService = HTMLPreviewBrowserToolService()
    let sumika = makeSumika(
      modelSettingsStore: modelSettingsStore,
      modelDownloader: modelDownloader,
      runtime: runtime,
      modelAvailability: modelAvailability,
      browserToolService: browserToolService,
      webAccessSettingsProvider: {
        await webAccessSettingsStore.settings()
      },
      turnTracer: turnTracer
    )

    return AppState(
      workspaceStore: workspaceStore,
      modelSettingsStore: modelSettingsStore,
      webAccessSettingsStore: webAccessSettingsStore,
      appBehaviorSettingsStore: appBehaviorSettingsStore,
      mcpServersStore: mcpServersStore,
      browserToolService: browserToolService,
      sumika: sumika,
      turnTracer: turnTracer
    )
  }

  @MainActor
  static func makeSumika(
    modelSettingsStore: any ModelSettingsStoring,
    modelDownloader: any ModelDownloading = UnavailableModelDownloader(),
    runtime: any ChatModelRuntime,
    modelAvailability: (@Sendable (ManagedModel) -> Bool)? = nil,
    browserToolService: any BrowserToolServing = UnavailableBrowserToolService(),
    webAccessSettingsProvider: @escaping @Sendable () async -> WebAccessSettings = {
      .disabled
    },
    turnTracer: any TurnTracing
  ) -> Sumika {
    let selectedModel = ManagedModelCatalog.defaultModel
    let storedSettings = StoredModelSettings(
      modeSettings: selectedModel.defaultModeSettings,
      contextTokenLimit: selectedModel.defaultContextTokenLimit
    )
    let sumika = Sumika(
      configuration: Sumika.Configuration(
        initialModel: selectedModel,
        initialModelSettings: storedSettings
      ),
      dependencies: Sumika.Dependencies(
        runtime: runtime,
        modelSettingsStore: modelSettingsStore,
        modelDownloader: modelDownloader,
        modelAvailability: modelAvailability,
        browserToolService: browserToolService,
        webAccessSettingsProvider: webAccessSettingsProvider,
        turnTracer: turnTracer
      )
    )
    sumika.models.loadPersistedModelSelection()
    return sumika
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
