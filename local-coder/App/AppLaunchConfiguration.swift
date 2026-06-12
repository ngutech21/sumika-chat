import Foundation
import LocalCoderCore

enum AppLaunchConfiguration {
  @MainActor
  static func makeAppState(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    runtime: (any ChatModelRuntime)? = nil
  ) -> AppState {
    if environment["LOCAL_CODER_UI_TEST_MODE"] == "1" {
      return makeUITestAppState(environment: environment, runtime: runtime ?? GemmaMLXRuntime())
    }

    if isXcodeUnitTestHost(environment: environment) {
      return makeUnitTestHostAppState(
        environment: environment, runtime: runtime ?? MockChatRuntime())
    }

    return AppState(runtime: runtime ?? GemmaMLXRuntime())
  }

  @MainActor
  private static func makeUITestAppState(
    environment: [String: String],
    runtime: any ChatModelRuntime
  ) -> AppState {
    let storageRoot = URL(
      filePath: environment["LOCAL_CODER_UI_TEST_STORAGE_ROOT"]
        ?? FileManager.default.temporaryDirectory
        .appending(path: "local-coder-ui-tests", directoryHint: .isDirectory)
        .path(percentEncoded: false),
      directoryHint: .isDirectory
    )
    let workspaceURL = URL(
      filePath: environment["LOCAL_CODER_UI_TEST_WORKSPACE_PATH"]
        ?? storageRoot.appending(path: "workspace", directoryHint: .isDirectory)
        .path(percentEncoded: false),
      directoryHint: .isDirectory
    )
    let modelID = environment["LOCAL_CODER_UI_TEST_MODEL_ID"] ?? "gemma4-e4b"
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
      runtime: runtime
    )
  }

  @MainActor
  private static func makeUnitTestHostAppState(
    environment: [String: String],
    runtime: any ChatModelRuntime
  ) -> AppState {
    let storageRoot = URL(
      filePath: environment["LOCAL_CODER_UNIT_TEST_STORAGE_ROOT"]
        ?? FileManager.default.temporaryDirectory
        .appending(path: "local-coder-unit-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
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
        suiteName: environment["LOCAL_CODER_UNIT_TEST_DEFAULTS_SUITE"]
          ?? "local-coder-unit-tests-\(UUID().uuidString)"
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
      systemPrompt: selectedModel.defaultSystemPrompt,
      generationSettings: selectedModel.defaultGenerationSettings,
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

  func loadLibrary() async -> WorkspaceLibrary {
    library
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
