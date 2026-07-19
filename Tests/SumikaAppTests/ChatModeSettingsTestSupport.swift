import SumikaCore

func testModeSettings(
  mode: WorkspaceInteractionMode = .chat,
  systemPrompt: String,
  generationSettings: ChatGenerationSettings
) -> ChatModeSettingsSet {
  var modeSettings = ChatModeSettingsSet.defaultSettings
  modeSettings[mode] = ChatModeSettings(
    systemPrompt: systemPrompt,
    generationSettings: generationSettings
  )
  return modeSettings
}
