package struct ModelContextDebugState: Equatable, Sendable {
  package var runtimeCacheDebugSnapshot: RuntimeCacheDebugSnapshot?
  package var documentRevision: Int

  package init(
    runtimeCacheDebugSnapshot: RuntimeCacheDebugSnapshot? = nil,
    documentRevision: Int = 0
  ) {
    self.runtimeCacheDebugSnapshot = runtimeCacheDebugSnapshot
    self.documentRevision = documentRevision
  }
}
