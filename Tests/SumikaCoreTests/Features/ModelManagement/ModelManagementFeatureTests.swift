import Foundation
import Testing

@testable import SumikaCore

@Suite(.serialized)
@MainActor
struct ModelManagementFeatureTests {
  @Test
  func modelDeletionIsDisabledWhileConversationIsGenerating() async {
    let engine = ConversationEngine(
      runtime: ModelManagementFeatureNoopRuntime(),
      modelPath: "/tmp/model",
      modelAvailability: { _ in true }
    )
    let feature = ModelManagementFeature(
      modelController: engine.modelRuntime,
      conversationEngine: engine
    )
    await feature.initialize()
    #expect(feature.canDeleteModel(ManagedModelCatalog.defaultModel))

    engine.isGenerating = true

    #expect(!feature.canDeleteModel(ManagedModelCatalog.defaultModel))
  }

  @Test
  func recommendedResetDoesNotUpdateReplacementSessionWithMatchingSettings() async throws {
    let model = ManagedModelCatalog.defaultModel
    let originalSettings = model.defaultModeSettings
    var recommendedSettings = originalSettings
    recommendedSettings.chat.generationSettings.temperature = 0.42
    let resolvedSettings = StoredModelSettings(
      modeSettings: recommendedSettings,
      contextTokenLimit: model.defaultContextTokenLimit
    )
    let settingsStore = SuspendedResetModelSettingsStore(
      initialSettings: StoredModelSettings(
        modeSettings: originalSettings,
        contextTokenLimit: model.defaultContextTokenLimit
      ),
      resetSettings: resolvedSettings
    )
    let firstSession = ChatSession(modeSettings: originalSettings)
    let replacementSession = ChatSession(modeSettings: originalSettings)
    let workspace = Workspace(
      name: "Test Workspace",
      rootURL: FileManager.default.temporaryDirectory,
      sessions: [firstSession, replacementSession]
    )
    let engine = ConversationEngine(
      runtime: ModelManagementFeatureNoopRuntime(),
      modelPath: "/tmp/model",
      modelSettingsStore: settingsStore,
      modelAvailability: { _ in true },
      chatSession: firstSession
    )
    try engine.loadSession(from: workspace, sessionID: firstSession.id)
    let feature = ModelManagementFeature(
      modelController: engine.modelRuntime,
      conversationEngine: engine
    )

    feature.useRecommendedSettings(for: .chat)
    await settingsStore.waitUntilApplyStarts()
    try engine.loadSession(from: workspace, sessionID: replacementSession.id)
    await settingsStore.releaseApply()
    await waitUntil {
      feature.resolvedModeSettings.chat == recommendedSettings.chat
    }

    #expect(engine.activeSessionID == replacementSession.id)
    #expect(engine.activeModeSettings == originalSettings)
    #expect(await settingsStore.appliedMutation == .resetMode(.chat))
  }
}

private actor SuspendedResetModelSettingsStore: ModelSettingsStoring {
  private var currentSettings: StoredModelSettings
  private let resetSettings: StoredModelSettings
  private var applyStartWaiters: [CheckedContinuation<Void, Never>] = []
  private var applyRelease: CheckedContinuation<Void, Never>?
  private var didStartApply = false
  private var isApplyReleased = false
  private(set) var appliedMutation: ModelSettingsMutation?

  init(
    initialSettings: StoredModelSettings,
    resetSettings: StoredModelSettings
  ) {
    currentSettings = initialSettings
    self.resetSettings = resetSettings
  }

  func setSelectedModelID(_: String) async {}

  func settings(for _: ManagedModel) async -> StoredModelSettings {
    currentSettings
  }

  func apply(
    _ mutation: ModelSettingsMutation,
    for _: ManagedModel
  ) async throws -> StoredModelSettings {
    appliedMutation = mutation
    didStartApply = true
    for waiter in applyStartWaiters {
      waiter.resume()
    }
    applyStartWaiters.removeAll()

    if !isApplyReleased {
      await withCheckedContinuation { continuation in
        applyRelease = continuation
      }
    }

    currentSettings = resetSettings
    return resetSettings
  }

  func waitUntilApplyStarts() async {
    guard !didStartApply else { return }
    await withCheckedContinuation { continuation in
      applyStartWaiters.append(continuation)
    }
  }

  func releaseApply() {
    isApplyReleased = true
    applyRelease?.resume()
    applyRelease = nil
  }
}

@MainActor
private func waitUntil(
  timeout: Duration = .seconds(1),
  condition: @escaping @MainActor () -> Bool
) async {
  let start = ContinuousClock.now
  while !condition() {
    if start.duration(to: .now) > timeout {
      Issue.record("Timed out waiting for condition")
      return
    }
    try? await Task.sleep(for: .milliseconds(10))
  }
}

private actor ModelManagementFeatureNoopRuntime: ChatModelRuntime {
  func load(configuration: ChatModelConfiguration) async throws {
    _ = configuration
  }

  func unload() async {}
  func clearContext() async {}

  func streamReply(
    for transcript: ModelPromptProjection,
    attachments: [ChatAttachment],
    promptPlan: ChatRuntimePromptPlan,
    settings: ChatGenerationSettings,
    interactionMode: WorkspaceInteractionMode?
  ) async throws -> AsyncThrowingStream<ChatModelStreamEvent, Error> {
    _ = transcript
    _ = attachments
    _ = promptPlan
    _ = settings
    _ = interactionMode
    return AsyncThrowingStream { $0.finish() }
  }
}
