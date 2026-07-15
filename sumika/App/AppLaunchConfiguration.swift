import Foundation
import SumikaCore

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
    if environment["SUMIKA_UI_TEST_MODE"] == "1" {
      return makeUITestAppState(environment: environment, runtime: runtime ?? MLXChatRuntime())
    }

    if isXcodeUnitTestHost(environment: environment) {
      return makeUnitTestHostAppState(
        environment: environment, runtime: runtime ?? MockChatRuntime())
    }

    return AppState(runtime: runtime ?? MLXChatRuntime())
  }

  @MainActor
  private static func makeUITestAppState(
    environment: [String: String],
    runtime: any ChatModelRuntime
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
      libraryURL: storageRoot.appending(path: "workspaces.json", directoryHint: .notDirectory),
      initialLibrary: makeUITestWorkspaceLibrary(
        workspaceURL: workspaceURL,
        selectedModel: selectedModel
      )
    )
    try? FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)

    return AppState(
      workspaceStore: workspaceStore,
      modelSettingsStore: modelSettingsStore,
      webAccessSettingsStore: webAccessSettingsStore,
      appBehaviorSettingsStore: appBehaviorSettingsStore,
      mcpServersStore: mcpServersStore,
      runtime: runtime
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

    return AppState(
      workspaceStore: WorkspaceStore(
        libraryURL: storageRoot.appending(path: "workspaces.json", directoryHint: .notDirectory)
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
      ),
      modelDownloader: UnavailableModelDownloader(),
      runtime: runtime,
      modelAvailability: { _ in false },
      turnTracer: NoopTurnTracer()
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

private actor UITestWorkspaceStore: WorkspaceStoring {
  private let libraryURL: URL
  private var library: WorkspaceLibrary

  init(libraryURL: URL, initialLibrary: WorkspaceLibrary) {
    self.libraryURL = libraryURL
    self.library = initialLibrary
  }

  func loadLibrary() async -> WorkspaceLibraryLoadResult {
    WorkspaceLibraryLoadResult(library: library)
  }

  func saveLibrary(_ library: WorkspaceLibrary) async throws {
    self.library = library
    try FileManager.default.createDirectory(
      at: libraryURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(library)
    try data.write(to: libraryURL, options: .atomic)
  }
}
