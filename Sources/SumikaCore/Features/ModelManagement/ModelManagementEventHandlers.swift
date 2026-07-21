struct ModelManagementEventHandlers {
  let modelDidChange: @MainActor (StoredModelSettings) -> Void
  let runtimeDidReset: @MainActor () -> Void
  let contextUsageShouldRefresh: @MainActor () async -> Void
  let errorDidOccur: @MainActor (String) -> Void

  init(
    modelDidChange: @escaping @MainActor (StoredModelSettings) -> Void,
    runtimeDidReset: @escaping @MainActor () -> Void,
    contextUsageShouldRefresh: @escaping @MainActor () async -> Void,
    errorDidOccur: @escaping @MainActor (String) -> Void
  ) {
    self.modelDidChange = modelDidChange
    self.runtimeDidReset = runtimeDidReset
    self.contextUsageShouldRefresh = contextUsageShouldRefresh
    self.errorDidOccur = errorDidOccur
  }
}
