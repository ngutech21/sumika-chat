import Foundation
import SumikaCore
import SumikaTestSupport
import Testing

@testable import SumikaApp

@MainActor
struct SettingsFeatureStateTests {
  @Test
  func loadReadsWebAndAppBehaviorSettings() async throws {
    let webSettings = WebAccessSettings(
      policy: .askEachTime,
      provider: .searxng,
      searxngBaseURL: "https://search.example"
    )
    let appBehaviorSettings = AppBehaviorSettings(
      autoloadLastModel: true,
      todoWriteToolEnabled: true,
      defaultInteractionMode: .agent,
      defaultToolApprovalPolicy: .automatic,
      assistantSpeechEnabled: true,
      assistantSpeechLanguageCode: "de-DE",
      assistantSpeechVoiceIdentifier: "voice.de",
      assistantSpeechRate: 0.42
    )
    let state = SettingsFeatureState(
      webAccessSettingsStore: InMemorySettingsWebAccessStore(settings: webSettings),
      appBehaviorSettingsStore: InMemorySettingsAppBehaviorStore(settings: appBehaviorSettings),
      mcpServersStore: InMemorySettingsMCPServersStore()
    )

    _ = await state.load()

    #expect(state.webAccessSettings == webSettings)
    #expect(state.appBehaviorSettings == appBehaviorSettings)
  }

  @Test
  func updateWebAccessSettingsPersistsSettings() async throws {
    let store = InMemorySettingsWebAccessStore()
    let state = SettingsFeatureState(
      webAccessSettingsStore: store,
      appBehaviorSettingsStore: InMemorySettingsAppBehaviorStore(),
      mcpServersStore: InMemorySettingsMCPServersStore()
    )
    let updated = WebAccessSettings(
      policy: .allow,
      provider: .searxng,
      searxngBaseURL: "https://search.example"
    )

    state.updateWebAccessSettings(updated)

    try await waitUntil {
      await store.snapshot() == updated
    }
    #expect(state.webAccessSettings == updated)
    #expect(state.errorMessage == nil)
  }

  @Test
  func updateAppBehaviorSettingsPersistsSettings() async throws {
    let store = InMemorySettingsAppBehaviorStore()
    let state = SettingsFeatureState(
      webAccessSettingsStore: InMemorySettingsWebAccessStore(),
      appBehaviorSettingsStore: store,
      mcpServersStore: InMemorySettingsMCPServersStore()
    )
    let updated = AppBehaviorSettings(
      autoloadLastModel: true,
      todoWriteToolEnabled: true,
      defaultInteractionMode: .agent,
      defaultToolApprovalPolicy: .automatic,
      assistantSpeechEnabled: true,
      assistantSpeechLanguageCode: "en-US",
      assistantSpeechVoiceIdentifier: "voice.en",
      assistantSpeechRate: 0.58
    )

    state.updateAppBehaviorSettings(updated)

    try await waitUntil {
      await store.snapshot() == updated
    }
    #expect(state.appBehaviorSettings == updated)
    #expect(state.errorMessage == nil)
  }

  @Test
  func legacyAppBehaviorSettingsDefaultNewSessionApprovalToManual() throws {
    let legacyData = Data(#"{"autoloadLastModel":true}"#.utf8)

    let settings = try JSONDecoder().decode(AppBehaviorSettings.self, from: legacyData)

    #expect(settings.autoloadLastModel)
    #expect(settings.defaultToolApprovalPolicy == .manual)
  }

  @Test
  func legacyAppBehaviorSettingsDefaultNewSessionInteractionModeToChat() throws {
    let legacyData = Data(#"{"autoloadLastModel":true}"#.utf8)

    let settings = try JSONDecoder().decode(AppBehaviorSettings.self, from: legacyData)

    #expect(settings.autoloadLastModel)
    #expect(settings.defaultInteractionMode == .chat)
  }

  @Test
  func appBehaviorSettingsRoundTripAutomaticNewSessionApproval() throws {
    let settings = AppBehaviorSettings(defaultToolApprovalPolicy: .automatic)

    let encoded = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(AppBehaviorSettings.self, from: encoded)

    #expect(decoded == settings)
  }

  @Test
  func appBehaviorSettingsRoundTripAgentNewSessionInteractionMode() throws {
    let settings = AppBehaviorSettings(defaultInteractionMode: .agent)

    let encoded = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(AppBehaviorSettings.self, from: encoded)

    #expect(decoded == settings)
  }

  @Test
  func rapidWebAccessUpdatesPersistInOrder() async throws {
    let store = SlowFirstSettingsWebAccessStore()
    let state = SettingsFeatureState(
      webAccessSettingsStore: store,
      appBehaviorSettingsStore: InMemorySettingsAppBehaviorStore(),
      mcpServersStore: InMemorySettingsMCPServersStore()
    )
    let first = WebAccessSettings(policy: .allow, provider: .duckDuckGo)
    let second = WebAccessSettings(
      policy: .askEachTime,
      provider: .searxng,
      searxngBaseURL: "https://search.example"
    )

    state.updateWebAccessSettings(first)
    state.updateWebAccessSettings(second)

    try await waitUntil(timeout: 3) {
      await store.saveCount() == 2
    }
    #expect(await store.snapshot() == second)
    #expect(state.webAccessSettings == second)
  }

  @Test
  func rapidAppBehaviorUpdatesPersistInOrder() async throws {
    let store = SlowFirstSettingsAppBehaviorStore()
    let state = SettingsFeatureState(
      webAccessSettingsStore: InMemorySettingsWebAccessStore(),
      appBehaviorSettingsStore: store,
      mcpServersStore: InMemorySettingsMCPServersStore()
    )
    let first = AppBehaviorSettings(autoloadLastModel: true)
    let second = AppBehaviorSettings(
      todoWriteToolEnabled: true,
      assistantSpeechEnabled: true,
      assistantSpeechLanguageCode: "de-DE",
      assistantSpeechVoiceIdentifier: "voice.de",
      assistantSpeechRate: 0.62
    )

    state.updateAppBehaviorSettings(first)
    state.updateAppBehaviorSettings(second)

    try await waitUntil(timeout: 3) {
      await store.saveCount() == 2
    }
    #expect(await store.snapshot() == second)
    #expect(state.appBehaviorSettings == second)
  }

  @Test
  func saveFailureSetsErrorMessage() async throws {
    let state = SettingsFeatureState(
      webAccessSettingsStore: FailingSettingsWebAccessStore(),
      appBehaviorSettingsStore: InMemorySettingsAppBehaviorStore(),
      mcpServersStore: InMemorySettingsMCPServersStore()
    )
    let updated = WebAccessSettings(policy: .allow, provider: .duckDuckGo)

    state.updateWebAccessSettings(updated)

    try await waitUntil {
      state.errorMessage == TestSettingsError.saveFailed.localizedDescription
    }
    #expect(state.webAccessSettings == updated)
  }

  @Test
  func successfulSaveDoesNotClearAnotherSettingsDomainFailure() async throws {
    let appBehaviorStore = InMemorySettingsAppBehaviorStore()
    let state = SettingsFeatureState(
      webAccessSettingsStore: FailingSettingsWebAccessStore(),
      appBehaviorSettingsStore: appBehaviorStore,
      mcpServersStore: InMemorySettingsMCPServersStore()
    )

    state.updateWebAccessSettings(WebAccessSettings(policy: .allow))
    try await waitUntil {
      state.errorMessage == TestSettingsError.saveFailed.localizedDescription
    }
    let appSettings = AppBehaviorSettings(autoloadLastModel: true)
    state.updateAppBehaviorSettings(appSettings)
    try await waitUntil {
      await appBehaviorStore.snapshot() == appSettings
    }

    #expect(state.errorMessage == TestSettingsError.saveFailed.localizedDescription)
  }

  @Test
  func failedMCPLoadIsUnavailableRatherThanAuthoritativeEmptyConfiguration() async {
    let state = SettingsFeatureState(
      webAccessSettingsStore: InMemorySettingsWebAccessStore(),
      appBehaviorSettingsStore: InMemorySettingsAppBehaviorStore(),
      mcpServersStore: FailingLoadSettingsMCPServersStore()
    )

    let outcome = await state.load()

    #expect(!outcome.hasAuthoritativeMCPServers)
    #expect(!state.hasAuthoritativeMCPServers)
    #expect(state.mcpServers.isEmpty)
    #expect(state.errorMessage == TestSettingsError.loadFailed.localizedDescription)
  }

  @Test
  func loadReadsMCPServersAndUpdatePersistsThem() async throws {
    let stored = MCPServerConfig(name: "GitHub", command: "npx", arguments: ["-y", "server"])
    let store = InMemorySettingsMCPServersStore(servers: [stored])
    let state = SettingsFeatureState(
      webAccessSettingsStore: InMemorySettingsWebAccessStore(),
      appBehaviorSettingsStore: InMemorySettingsAppBehaviorStore(),
      mcpServersStore: store
    )

    _ = await state.load()
    #expect(state.mcpServers == [stored])

    let replacement = MCPServerConfig(name: "Local", command: "/usr/local/bin/mcp")
    state.stageMCPServersUpdate([replacement])
    let saveOutcome = await state.persistMCPServers([replacement])
    state.settleMCPServersUpdate(
      authoritativeServers: saveOutcome.didSave ? [replacement] : nil,
      saveOutcome: saveOutcome
    )

    #expect(saveOutcome == .saved)
    #expect(await store.snapshot() == [replacement])
    #expect(state.mcpServers == [replacement])
    #expect(state.errorMessage == nil)
  }

  @Test
  func mcpServerEditorDraftBuildsStdioConfiguration() throws {
    let existing = MCPServerConfig(
      name: "Existing",
      command: "npx",
      isEnabled: false
    )
    var draft = MCPServerEditorDraft(server: existing)
    draft.name = " Local "
    draft.command = " uvx "
    draft.argumentsText = "--flag\nvalue"
    draft.environmentText = "TOKEN=secret\nEMPTY="

    let server = try #require(draft.server(replacing: existing))

    #expect(server.id == existing.id)
    #expect(server.name == "Local")
    #expect(!server.isEnabled)
    #expect(
      server.transport
        == .stdio(
          command: "uvx",
          arguments: ["--flag", "value"],
          environment: ["TOKEN": "secret", "EMPTY": ""]
        )
    )
    #expect(server.connectionDescription == "uvx --flag value")
  }

  @Test
  func mcpServerEditorDraftBuildsStreamableHTTPConfiguration() throws {
    var draft = MCPServerEditorDraft()
    draft.name = "Remote"
    draft.transport = .streamableHTTP
    draft.endpoint = " https://mcp.example.com/mcp "

    let server = try #require(draft.server())

    #expect(draft.isValid)
    #expect(draft.endpointError == nil)
    #expect(
      server.transport
        == .streamableHTTP(
          endpoint: try #require(URL(string: "https://mcp.example.com/mcp"))
        )
    )
    #expect(server.connectionDescription == "https://mcp.example.com/mcp")
  }

  @Test
  func mcpServerEditorDraftRejectsRemotePlainHTTP() {
    var draft = MCPServerEditorDraft()
    draft.name = "Unsafe"
    draft.transport = .streamableHTTP
    draft.endpoint = "http://mcp.example.com/mcp"

    #expect(!draft.isValid)
    #expect(draft.endpointError as? MCPServerEndpointError == .insecureRemoteHTTP)
    #expect(draft.server() == nil)
  }
}

@Suite(TemporaryDirectoryTrait(named: "sumika-app-behavior-settings-store-tests"))
@MainActor
struct AppBehaviorSettingsStoreTests {
  @Test
  func loadReturnsDefaultsWhenFileIsMissing() async throws {
    let url = try makeURL(named: "app-behavior-settings-missing.json")

    let settings = try await AppBehaviorSettingsStore(settingsURL: url).load()

    #expect(settings == AppBehaviorSettings())
    #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
  }

  @Test
  func saveWritesVersionOneAndRoundTripsSettings() async throws {
    let url = try makeURL(named: "app-behavior-settings.json")
    let settings = AppBehaviorSettings(
      autoloadLastModel: true,
      todoWriteToolEnabled: true,
      defaultInteractionMode: .agent,
      defaultToolApprovalPolicy: .automatic,
      assistantSpeechEnabled: true,
      assistantSpeechLanguageCode: "en-US",
      assistantSpeechVoiceIdentifier: "voice.en",
      assistantSpeechRate: 0.58,
      speechInputAudioModelID: "speech-model"
    )

    try await AppBehaviorSettingsStore(settingsURL: url).save(settings: settings)

    #expect(try await AppBehaviorSettingsStore(settingsURL: url).load() == settings)
    let persisted = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    )
    #expect(persisted["schemaVersion"] as? Int == 1)
    #expect(persisted["autoloadLastModel"] as? Bool == true)
    #expect(persisted["defaultInteractionMode"] as? String == "agent")
    #expect(persisted["settings"] == nil)

    let legacyDecoded = try JSONDecoder().decode(
      AppBehaviorSettings.self,
      from: Data(contentsOf: url)
    )
    #expect(legacyDecoded == settings)
  }

  @Test
  func loadMigratesUnversionedFileToVersionOne() async throws {
    let url = try makeURL(named: "app-behavior-settings-v0.json")
    try write(
      """
      {
        "autoloadLastModel": true,
        "todoWriteToolEnabled": true,
        "defaultInteractionMode": "agent",
        "defaultToolApprovalPolicy": "automatic",
        "assistantSpeechEnabled": true,
        "assistantSpeechLanguageCode": "de-DE",
        "assistantSpeechVoiceIdentifier": "voice.de",
        "assistantSpeechRate": 0.42,
        "speechInputAudioModelID": "speech-model"
      }
      """,
      to: url
    )

    let settings = try await AppBehaviorSettingsStore(settingsURL: url).load()

    #expect(
      settings
        == AppBehaviorSettings(
          autoloadLastModel: true,
          todoWriteToolEnabled: true,
          defaultInteractionMode: .agent,
          defaultToolApprovalPolicy: .automatic,
          assistantSpeechEnabled: true,
          assistantSpeechLanguageCode: "de-DE",
          assistantSpeechVoiceIdentifier: "voice.de",
          assistantSpeechRate: 0.42,
          speechInputAudioModelID: "speech-model"
        )
    )
    let migrated = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    )
    #expect(migrated["schemaVersion"] as? Int == 1)
    #expect(migrated["autoloadLastModel"] as? Bool == true)
    #expect(migrated["defaultInteractionMode"] as? String == "agent")
    #expect(migrated["settings"] == nil)
  }

  @Test
  func loadAcceptsCurrentVersionWithoutRewritingIt() async throws {
    let url = try makeURL(named: "app-behavior-settings-v1.json")
    let current = """
      {
        "schemaVersion": 1,
        "autoloadLastModel": true,
        "todoWriteToolEnabled": false,
        "defaultInteractionMode": "chat",
        "defaultToolApprovalPolicy": "manual",
        "assistantSpeechEnabled": false,
        "assistantSpeechRate": 0.5
      }
      """
    try write(current, to: url)
    let originalData = try Data(contentsOf: url)

    let settings = try await AppBehaviorSettingsStore(settingsURL: url).load()

    #expect(settings == AppBehaviorSettings(autoloadLastModel: true, assistantSpeechRate: 0.5))
    #expect(try Data(contentsOf: url) == originalData)
  }

  @Test
  func loadRejectsMalformedFileWithoutRewritingIt() async throws {
    let url = try makeURL(named: "app-behavior-settings-malformed.json")
    let malformed = #"{"autoloadLastModel":"yes"}"#
    try write(malformed, to: url)
    let originalData = try Data(contentsOf: url)

    await #expect(
      throws: VersionedJSONFileError.decodeFailed(
        fileName: "app-behavior-settings-malformed.json",
        schemaVersion: 0
      )
    ) {
      try await AppBehaviorSettingsStore(settingsURL: url).load()
    }
    #expect(try Data(contentsOf: url) == originalData)
  }

  @Test
  func loadRejectsFutureVersionWithoutRewritingIt() async throws {
    let url = try makeURL(named: "app-behavior-settings-future.json")
    let future = #"{"schemaVersion":2,"settings":{}}"#
    try write(future, to: url)
    let originalData = try Data(contentsOf: url)

    await #expect(
      throws: VersionedJSONFileError.unsupportedSchemaVersion(
        fileName: "app-behavior-settings-future.json",
        found: 2,
        current: 1
      )
    ) {
      try await AppBehaviorSettingsStore(settingsURL: url).load()
    }
    #expect(try Data(contentsOf: url) == originalData)
  }

  private func makeURL(named fileName: String) throws -> URL {
    try scopedTemporaryDirectory().appending(path: fileName, directoryHint: .notDirectory)
  }

  private func write(_ json: String, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(json.utf8).write(to: url)
  }
}

private actor InMemorySettingsMCPServersStore: MCPServersStoring {
  private var storedServers: [MCPServerConfig]

  init(servers: [MCPServerConfig] = []) {
    self.storedServers = servers
  }

  func load() async throws -> [MCPServerConfig] {
    storedServers
  }

  func snapshot() -> [MCPServerConfig] {
    storedServers
  }

  func save(servers: [MCPServerConfig]) async throws {
    storedServers = servers
  }
}

private actor InMemorySettingsWebAccessStore: WebAccessSettingsStoring {
  private var storedSettings: WebAccessSettings

  init(settings: WebAccessSettings = .disabled) {
    self.storedSettings = settings
  }

  func load() async throws -> WebAccessSettings {
    storedSettings
  }

  func snapshot() -> WebAccessSettings {
    storedSettings
  }

  func save(settings: WebAccessSettings) async throws {
    storedSettings = settings
  }
}

private actor InMemorySettingsAppBehaviorStore: AppBehaviorSettingsStoring {
  private var storedSettings: AppBehaviorSettings

  init(settings: AppBehaviorSettings = AppBehaviorSettings()) {
    self.storedSettings = settings
  }

  func load() async throws -> AppBehaviorSettings {
    storedSettings
  }

  func snapshot() -> AppBehaviorSettings {
    storedSettings
  }

  func save(settings: AppBehaviorSettings) async throws {
    storedSettings = settings
  }
}

private actor SlowFirstSettingsWebAccessStore: WebAccessSettingsStoring {
  private var storedSettings = WebAccessSettings.disabled
  private var saves = 0

  func load() async throws -> WebAccessSettings {
    storedSettings
  }

  func snapshot() -> WebAccessSettings {
    storedSettings
  }

  func save(settings: WebAccessSettings) async throws {
    saves += 1
    if saves == 1 {
      try await Task.sleep(for: .milliseconds(100))
    }
    storedSettings = settings
  }

  func saveCount() -> Int {
    saves
  }
}

private actor SlowFirstSettingsAppBehaviorStore: AppBehaviorSettingsStoring {
  private var storedSettings = AppBehaviorSettings()
  private var saves = 0

  func load() async throws -> AppBehaviorSettings {
    storedSettings
  }

  func snapshot() -> AppBehaviorSettings {
    storedSettings
  }

  func save(settings: AppBehaviorSettings) async throws {
    saves += 1
    if saves == 1 {
      try await Task.sleep(for: .milliseconds(100))
    }
    storedSettings = settings
  }

  func saveCount() -> Int {
    saves
  }
}

private actor FailingSettingsWebAccessStore: WebAccessSettingsStoring {
  func load() async throws -> WebAccessSettings {
    .disabled
  }

  func save(settings: WebAccessSettings) async throws {
    _ = settings
    throw TestSettingsError.saveFailed
  }
}

private actor FailingLoadSettingsMCPServersStore: MCPServersStoring {
  func load() async throws -> [MCPServerConfig] {
    throw TestSettingsError.loadFailed
  }

  func save(servers _: [MCPServerConfig]) async throws {
    throw TestSettingsError.saveFailed
  }
}

private enum TestSettingsError: LocalizedError {
  case loadFailed
  case saveFailed

  var errorDescription: String? {
    switch self {
    case .loadFailed:
      "Settings load failed."
    case .saveFailed:
      "Settings save failed."
    }
  }
}

private func waitUntil(
  timeout: TimeInterval = 2,
  condition: @escaping () async -> Bool
) async throws {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if await condition() {
      return
    }
    try await Task.sleep(for: .milliseconds(10))
  }
  Issue.record("Timed out waiting for condition.")
}
