import Foundation

public struct ModelContextDebugState: Equatable, Sendable {
  public var runtimeCacheDebugSnapshot: RuntimeCacheDebugSnapshot?
  public var documentRevision: Int

  public init(
    runtimeCacheDebugSnapshot: RuntimeCacheDebugSnapshot? = nil,
    documentRevision: Int = 0
  ) {
    self.runtimeCacheDebugSnapshot = runtimeCacheDebugSnapshot
    self.documentRevision = documentRevision
  }
}
