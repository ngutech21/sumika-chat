import Foundation

nonisolated struct GemmaGenerationID: Equatable, Hashable, Sendable {
  let rawValue: UInt64
}

nonisolated struct GemmaGenerationOwnership: Equatable, Sendable {
  private var nextRawValue: UInt64 = 0
  private(set) var activeGenerationID: GemmaGenerationID?

  mutating func beginGeneration() -> GemmaGenerationID {
    nextRawValue &+= 1
    let generationID = GemmaGenerationID(rawValue: nextRawValue)
    activeGenerationID = generationID
    return generationID
  }

  mutating func completeIfCurrent(_ generationID: GemmaGenerationID) -> Bool {
    guard activeGenerationID == generationID else {
      return false
    }
    activeGenerationID = nil
    return true
  }

  mutating func invalidateIfCurrent(_ generationID: GemmaGenerationID) -> Bool {
    guard activeGenerationID == generationID else {
      return false
    }
    activeGenerationID = nil
    return true
  }

  mutating func invalidateActiveGeneration() {
    activeGenerationID = nil
  }
}

nonisolated struct ActiveGemmaGeneration: Sendable {
  let id: GemmaGenerationID
  let task: Task<Void, Never>
}

nonisolated struct GemmaActiveGenerationRegistry: Sendable {
  private(set) var activeGeneration: ActiveGemmaGeneration?

  var activeGenerationID: GemmaGenerationID? {
    activeGeneration?.id
  }

  mutating func register(id: GemmaGenerationID, task: Task<Void, Never>) {
    activeGeneration = ActiveGemmaGeneration(id: id, task: task)
  }

  mutating func supersedeActiveGeneration() -> ActiveGemmaGeneration? {
    guard let activeGeneration else {
      return nil
    }
    self.activeGeneration = nil
    activeGeneration.task.cancel()
    return activeGeneration
  }

  @discardableResult
  mutating func clearIfCurrent(_ generationID: GemmaGenerationID) -> Bool {
    guard activeGeneration?.id == generationID else {
      return false
    }
    activeGeneration = nil
    return true
  }
}
