import Foundation
import LocalCoderCore

enum AppLaunchConfiguration {
  @MainActor
  static func makeAppState(environment: [String: String] = ProcessInfo.processInfo.environment)
    -> AppState
  {
    guard environment["LOCAL_CODER_UI_TEST_MODE"] == "1" else {
      return AppState()
    }

    return makeUITestAppState(environment: environment)
  }

  @MainActor
  private static func makeUITestAppState(environment: [String: String]) -> AppState {
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
    let browserToolService = HTMLPreviewBrowserToolService()

    let controller = ChatSessionController(
      modelSettingsStore: modelSettingsStore,
      modelDownloader: HuggingFaceModelDownloader(),
      runtime: GemmaMLXRuntime(),
      toolOrchestrator: ToolOrchestrator(
        executorRegistry: .codingAgent,
        browserToolService: browserToolService,
        webAccessSettingsProvider: {
          await webAccessSettingsStore.settings()
        }
      ),
      turnTracer: GemmaDebugTraceStore.shared
    )
    return AppState(
      workspaceStore: workspaceStore,
      modelSettingsStore: modelSettingsStore,
      webAccessSettingsStore: webAccessSettingsStore,
      appBehaviorSettingsStore: appBehaviorSettingsStore,
      chatController: controller
    )
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
