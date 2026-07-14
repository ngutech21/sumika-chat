import Foundation
import SumikaCore
import Testing

@testable import Sumika

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

    await state.load()

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
      await store.settings() == updated
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
      assistantSpeechEnabled: true,
      assistantSpeechLanguageCode: "en-US",
      assistantSpeechVoiceIdentifier: "voice.en",
      assistantSpeechRate: 0.58
    )

    state.updateAppBehaviorSettings(updated)

    try await waitUntil {
      await store.settings() == updated
    }
    #expect(state.appBehaviorSettings == updated)
    #expect(state.errorMessage == nil)
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
    #expect(await store.settings() == second)
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
    #expect(await store.settings() == second)
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
  func loadReadsMCPServersAndUpdatePersistsThem() async throws {
    let stored = MCPServerConfig(name: "GitHub", command: "npx", arguments: ["-y", "server"])
    let store = InMemorySettingsMCPServersStore(servers: [stored])
    let state = SettingsFeatureState(
      webAccessSettingsStore: InMemorySettingsWebAccessStore(),
      appBehaviorSettingsStore: InMemorySettingsAppBehaviorStore(),
      mcpServersStore: store
    )

    await state.load()
    #expect(state.mcpServers == [stored])

    let replacement = MCPServerConfig(name: "Local", command: "/usr/local/bin/mcp")
    state.updateMCPServers([replacement])

    try await waitUntil {
      await store.servers() == [replacement]
    }
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

private actor InMemorySettingsMCPServersStore: MCPServersStoring {
  private var storedServers: [MCPServerConfig]

  init(servers: [MCPServerConfig] = []) {
    self.storedServers = servers
  }

  func servers() async -> [MCPServerConfig] {
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

  func settings() async -> WebAccessSettings {
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

  func settings() async -> AppBehaviorSettings {
    storedSettings
  }

  func save(settings: AppBehaviorSettings) async throws {
    storedSettings = settings
  }
}

private actor SlowFirstSettingsWebAccessStore: WebAccessSettingsStoring {
  private var storedSettings = WebAccessSettings.disabled
  private var saves = 0

  func settings() async -> WebAccessSettings {
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

  func settings() async -> AppBehaviorSettings {
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
  func settings() async -> WebAccessSettings {
    .disabled
  }

  func save(settings: WebAccessSettings) async throws {
    _ = settings
    throw TestSettingsError.saveFailed
  }
}

private enum TestSettingsError: LocalizedError {
  case saveFailed

  var errorDescription: String? {
    "Settings save failed."
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
