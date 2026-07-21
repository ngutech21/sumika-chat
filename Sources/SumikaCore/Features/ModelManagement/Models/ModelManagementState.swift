package struct ModelManagementState: Equatable, Sendable {
  package let availableModels: [ManagedModel]
  package let selectedModel: ManagedModel
  package let downloadedModelIDs: Set<ManagedModel.ID>
  package let downloadState: ModelDownloadState
  package let modelState: ModelLoadState
  package let modelContextTokenLimit: Int
  package let modelGenerationConfigPreset: ChatGenerationConfigPreset?
  package let processUsage: ProcessResourceUsage?
  package let canChangeModel: Bool

  package func isModelDownloaded(_ model: ManagedModel) -> Bool {
    downloadedModelIDs.contains(model.id)
  }
}
