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
