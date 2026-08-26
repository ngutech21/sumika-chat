import Testing

@testable import SumikaCore

struct ModelSettingsResolverTests {
  @Test
  func reasoningSelectionsResolveAgainstModelCapability() throws {
    let qwen = try #require(ManagedModelCatalog.model(id: "qwen3.8-27B-OptiQ-4bit"))
    let binary = ManagedModelCatalog.defaultModel

    let qwenDefaults = ModelSettingsResolver.recommendedSettings(
      for: qwen,
      generationConfig: nil
    )
    let binaryDefaults = ModelSettingsResolver.recommendedSettings(
      for: binary,
      generationConfig: nil
    )
    let binaryWithEffortOverride = ModelSettingsResolver.settings(
      for: binary,
      generationConfig: nil,
      userOverrides: ModelSettingsOverrides(
        chat: ModeSettingsOverride(
          generationSettings: GenerationSettingsOverride(
            reasoningSelection: .effort(.xhigh)
          )
        )
      )
    )

    #expect(
      qwenDefaults.modeSettings.chat.generationSettings.reasoningSelection
        == .effort(.medium)
    )
    #expect(
      qwenDefaults.modeSettings.agent.generationSettings.reasoningSelection
        == .effort(.medium)
    )
    #expect(binaryDefaults.modeSettings.chat.generationSettings.reasoningSelection == .on)
    #expect(binaryWithEffortOverride.modeSettings.chat.generationSettings.reasoningSelection == .on)

    let futureCapability = ModelReasoningCapability.selectableEffort(
      supported: [.medium],
      defaultValue: .medium
    )
    #expect(futureCapability.resolving(.effort(.xhigh)) == .effort(.medium))
  }

  @Test
  func userOverridesWinFieldByFieldIncludingExplicitZero() throws {
    let model = try #require(ManagedModelCatalog.model(id: "qwen3.6-35b-a3b-optiq-4bit"))
    let userOverrides = ModelSettingsOverrides(
      chat: ModeSettingsOverride(
        systemPrompt: "Use my chat policy.",
        generationSettings: GenerationSettingsOverride(
          temperature: 0,
          topP: 0,
          topK: 0,
          minP: 0,
          presencePenalty: 0
        )
      ),
      contextTokenLimit: 32_768
    )

    let settings = ModelSettingsResolver.settings(
      for: model,
      generationConfig: GenerationSettingsOverride(
        temperature: 0.7,
        topP: 0.8,
        topK: 20,
        minP: 0.1,
        presencePenalty: 1.5
      ),
      userOverrides: userOverrides
    )

    #expect(settings.modeSettings.chat.systemPrompt == "Use my chat policy.")
    #expect(settings.modeSettings.chat.generationSettings.temperature == 0)
    #expect(settings.modeSettings.chat.generationSettings.topP == 0)
    #expect(settings.modeSettings.chat.generationSettings.topK == 0)
    #expect(settings.modeSettings.chat.generationSettings.minP == 0)
    #expect(settings.modeSettings.chat.generationSettings.presencePenalty == 0)
    #expect(settings.modeSettings.agent.generationSettings.temperature == 0.6)
    #expect(settings.modeSettings.agent.generationSettings.presencePenalty == 0)
    #expect(settings.contextTokenLimit == 32_768)
  }

  @Test
  func mtpOverrideAppliesOnlyToModelsWithADrafter() throws {
    let supported = try #require(
      ManagedModelCatalog.model(id: "Qwen3.6-27B-OptiQ-4bit")
    )
    let unsupported = ManagedModelCatalog.defaultModel
    let overrides = ModelSettingsOverrides(
      chat: ModeSettingsOverride(
        generationSettings: GenerationSettingsOverride(isMTPEnabled: true)
      )
    )

    let supportedSettings = ModelSettingsResolver.settings(
      for: supported,
      generationConfig: nil,
      userOverrides: overrides
    )
    let unsupportedSettings = ModelSettingsResolver.settings(
      for: unsupported,
      generationConfig: nil,
      userOverrides: overrides
    )

    #expect(supportedSettings.modeSettings.chat.generationSettings.isMTPEnabled)
    #expect(supportedSettings.modeSettings.chat.generationSettings.temperature == 0)
    #expect(!unsupportedSettings.modeSettings.chat.generationSettings.isMTPEnabled)
    #expect(
      unsupportedSettings.modeSettings.chat.generationSettings.temperature
        == unsupported.defaultModeSettings.chat.generationSettings.temperature
    )
  }

  @Test
  func temperatureOverrideAppliesAfterDisablingMTP() {
    var mtpSettings = ChatGenerationSettings.chatDefault
    mtpSettings.temperature = 0.8
    mtpSettings.isMTPEnabled = true

    let settings = GenerationSettingsOverride(
      temperature: 0.8,
      isMTPEnabled: false
    ).applying(to: mtpSettings)

    #expect(!settings.isMTPEnabled)
    #expect(settings.temperature == 0.8)
  }

  @Test
  func familyProfilesOverrideTheirRecommendedSamplerFields() throws {
    let generationConfig = GenerationSettingsOverride(
      temperature: 1.4,
      topP: 0.8,
      topK: 99,
      minP: 0.12,
      repetitionPenalty: 1.1,
      presencePenalty: 1.5
    )

    let gemma = try #require(ManagedModelCatalog.model(id: "gemma4-12b-qat-4bit"))
    let gemmaSettings = ModelSettingsResolver.recommendedSettings(
      for: gemma,
      generationConfig: generationConfig
    ).modeSettings
    #expect(gemmaSettings.chat.generationSettings.temperature == 1)
    #expect(gemmaSettings.chat.generationSettings.topP == 0.95)
    #expect(gemmaSettings.chat.generationSettings.topK == 64)
    #expect(gemmaSettings.agent.generationSettings.temperature == 0.7)
    #expect(gemmaSettings.agent.generationSettings.topP == 0.9)
    #expect(gemmaSettings.agent.generationSettings.topK == 0)
    #expect(gemmaSettings.chat.generationSettings.presencePenalty == 1.5)
    #expect(gemmaSettings.agent.generationSettings.presencePenalty == 1.5)

    let qwen36 = try #require(ManagedModelCatalog.model(id: "qwen3.6-35b-a3b-8bit"))
    let qwen36Settings = ModelSettingsResolver.recommendedSettings(
      for: qwen36,
      generationConfig: generationConfig
    ).modeSettings
    #expect(qwen36Settings.chat.generationSettings.temperature == 0.7)
    #expect(qwen36Settings.chat.generationSettings.topP == 0.9)
    #expect(qwen36Settings.chat.generationSettings.topK == 0)
    #expect(qwen36Settings.agent.generationSettings.temperature == 0.6)
    #expect(qwen36Settings.agent.generationSettings.topP == 0.95)
    #expect(qwen36Settings.agent.generationSettings.topK == 20)
    #expect(qwen36Settings.chat.generationSettings.presencePenalty == 0)
    #expect(qwen36Settings.agent.generationSettings.presencePenalty == 0)

    let qwen38 = try #require(ManagedModelCatalog.model(id: "qwen3.8-27B-OptiQ-4bit"))
    let qwen38Settings = ModelSettingsResolver.recommendedSettings(
      for: qwen38,
      generationConfig: generationConfig
    ).modeSettings
    var qwen38ChatSampling = qwen38Settings.chat.generationSettings
    qwen38ChatSampling.reasoningSelection = .on
    var qwen38AgentSampling = qwen38Settings.agent.generationSettings
    qwen38AgentSampling.reasoningSelection = .on
    #expect(qwen38ChatSampling == qwen36Settings.chat.generationSettings)
    #expect(qwen38AgentSampling == qwen36Settings.agent.generationSettings)

    for settings in [gemmaSettings, qwen36Settings, qwen38Settings] {
      #expect(settings.chat.generationSettings.minP == 0.12)
      #expect(settings.agent.generationSettings.minP == 0.12)
      #expect(settings.chat.generationSettings.repetitionPenalty == 1.1)
      #expect(settings.agent.generationSettings.repetitionPenalty == 1.1)
    }
  }

  @Test
  func unprofiledOptiQNamedModelUsesOnlyConfigAndAppFallbacks() {
    let model = ManagedModel(
      id: "future-optiq-model",
      displayName: "Future OptiQ Model",
      detail: "Unprofiled fixture",
      huggingFaceRepoID: "example/Future-OptiQ-4bit",
      localDirectoryName: "future-optiq-model",
      estimatedDownloadSize: "1 MB",
      group: .specialized,
      requiresLargeMemory: false,
      stability: .experimental,
      supportsImageInput: false,
      defaultModeSettings: .defaultSettings,
      defaultContextTokenLimit: 4096
    )
    let partialConfig = GenerationSettingsOverride(topP: 0.82, minP: 0)

    let settings = ModelSettingsResolver.recommendedSettings(
      for: model,
      generationConfig: partialConfig
    )

    #expect(settings.modeSettings.chat.generationSettings.temperature == 1)
    #expect(settings.modeSettings.chat.generationSettings.topP == 0.82)
    #expect(settings.modeSettings.chat.generationSettings.topK == 0)
    #expect(settings.modeSettings.chat.generationSettings.minP == 0)
    #expect(settings.modeSettings.agent.generationSettings.temperature == 0.3)
    #expect(settings.modeSettings.agent.generationSettings.topP == 0.82)
    #expect(settings.modeSettings.agent.generationSettings.topK == 64)
    #expect(settings.modeSettings.agent.generationSettings.minP == 0)

    let withoutConfig = ModelSettingsResolver.recommendedSettings(
      for: model,
      generationConfig: nil
    )
    #expect(withoutConfig.modeSettings == ChatModeSettingsSet.defaultSettings)
  }
}
