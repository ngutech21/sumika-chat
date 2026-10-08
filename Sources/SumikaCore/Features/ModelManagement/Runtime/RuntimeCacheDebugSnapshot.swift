import Foundation

/// Allocated cache array capacity, including reserved space and recurrent state.
package struct RuntimeCacheAllocationSnapshot: Equatable, Sendable {
  package enum Phase: String, Equatable, Sendable {
    case planned
    case realized
  }

  package struct Layer: Equatable, Sendable {
    package let path: [Int]
    package let kind: String
    package let allocatedBytes: Int

    package init(path: [Int], kind: String, allocatedBytes: Int) {
      self.path = path
      self.kind = kind
      self.allocatedBytes = allocatedBytes
    }
  }

  package let phase: Phase
  package let allocatedBytes: Int
  package let layers: [Layer]

  package init(phase: Phase, allocatedBytes: Int, layers: [Layer]) {
    self.phase = phase
    self.allocatedBytes = allocatedBytes
    self.layers = layers
  }
}

package struct RuntimeCacheDebugSnapshot: Equatable, Sendable {
  package let generationID: UUID
  package let recordedAt: Date
  package let cacheMode: String
  package let cacheReason: String
  package let reuseStrategy: String
  package let appendDeltaStartIndex: Int?
  package let contextSignature: String
  package let previousContextSignature: String?
  package let appendOnly: Bool
  package let reusedMessageCount: Int
  package let appendedMessageCount: Int
  package let mismatchReason: String?
  package let firstMismatchIndex: Int?
  package let systemPromptChanged: Bool?
  package var cacheAllocationBefore: RuntimeCacheAllocationSnapshot?
  package var cacheAllocationAfter: RuntimeCacheAllocationSnapshot?

  package init(
    generationID: UUID,
    recordedAt: Date,
    cacheMode: String,
    cacheReason: String,
    reuseStrategy: String,
    appendDeltaStartIndex: Int? = nil,
    contextSignature: String,
    previousContextSignature: String? = nil,
    appendOnly: Bool,
    reusedMessageCount: Int,
    appendedMessageCount: Int,
    mismatchReason: String? = nil,
    firstMismatchIndex: Int? = nil,
    systemPromptChanged: Bool? = nil
  ) {
    self.generationID = generationID
    self.recordedAt = recordedAt
    self.cacheMode = cacheMode
    self.cacheReason = cacheReason
    self.reuseStrategy = reuseStrategy
    self.appendDeltaStartIndex = appendDeltaStartIndex
    self.contextSignature = contextSignature
    self.previousContextSignature = previousContextSignature
    self.appendOnly = appendOnly
    self.reusedMessageCount = reusedMessageCount
    self.appendedMessageCount = appendedMessageCount
    self.mismatchReason = mismatchReason
    self.firstMismatchIndex = firstMismatchIndex
    self.systemPromptChanged = systemPromptChanged
  }
}
