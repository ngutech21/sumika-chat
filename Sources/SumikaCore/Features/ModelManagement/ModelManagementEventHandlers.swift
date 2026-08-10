struct ModelManagementEventHandlers {
  let modelDidChange: @MainActor (StoredModelSettings) -> Void
  let runtimeDidReset: @MainActor () -> Void
  let errorDidOccur: @MainActor (String) -> Void

  init(
    modelDidChange: @escaping @MainActor (StoredModelSettings) -> Void,
    runtimeDidReset: @escaping @MainActor () -> Void,
    errorDidOccur: @escaping @MainActor (String) -> Void
  ) {
    self.modelDidChange = modelDidChange
    self.runtimeDidReset = runtimeDidReset
    self.errorDidOccur = errorDidOccur
  }
}
