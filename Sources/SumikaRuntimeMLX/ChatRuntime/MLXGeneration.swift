struct MLXGenerationID: Equatable, Hashable, Sendable {
  let rawValue: UInt64
}

struct MLXGenerationOwnership: Equatable, Sendable {
  private var nextRawValue: UInt64 = 0
  private(set) var activeGenerationID: MLXGenerationID?

  mutating func beginGeneration() -> MLXGenerationID {
    nextRawValue &+= 1
    let generationID = MLXGenerationID(rawValue: nextRawValue)
    activeGenerationID = generationID
    return generationID
  }

  mutating func completeIfCurrent(_ generationID: MLXGenerationID) -> Bool {
    guard activeGenerationID == generationID else {
      return false
    }
    activeGenerationID = nil
    return true
  }

  mutating func invalidateIfCurrent(_ generationID: MLXGenerationID) -> Bool {
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

struct ActiveMLXGeneration: Sendable {
  let id: MLXGenerationID
  let task: Task<Void, Never>
}

struct MLXActiveGenerationRegistry: Sendable {
  private(set) var activeGeneration: ActiveMLXGeneration?

  mutating func register(id: MLXGenerationID, task: Task<Void, Never>) {
    activeGeneration = ActiveMLXGeneration(id: id, task: task)
  }

  mutating func supersedeActiveGeneration() -> ActiveMLXGeneration? {
    guard let activeGeneration else {
      return nil
    }
    self.activeGeneration = nil
    activeGeneration.task.cancel()
    return activeGeneration
  }

  @discardableResult
  mutating func clearIfCurrent(_ generationID: MLXGenerationID) -> Bool {
    guard activeGeneration?.id == generationID else {
      return false
    }
    activeGeneration = nil
    return true
  }
}
