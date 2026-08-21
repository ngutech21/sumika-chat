struct MLXGenerationID: Equatable, Hashable, Sendable {
  let rawValue: UInt64
}

struct MLXGenerationSetupID: Equatable, Hashable, Sendable {
  let rawValue: UInt64
}

struct MLXGenerationSetupOwnership: Equatable, Sendable {
  private var nextRawValue: UInt64 = 0
  private(set) var currentSetupID: MLXGenerationSetupID?

  mutating func beginSetup() -> MLXGenerationSetupID {
    nextRawValue &+= 1
    let setupID = MLXGenerationSetupID(rawValue: nextRawValue)
    currentSetupID = setupID
    return setupID
  }

  func isCurrent(_ setupID: MLXGenerationSetupID) -> Bool {
    currentSetupID == setupID
  }
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
  private var activeGeneration: ActiveMLXGeneration?
  private var drainingGeneration: ActiveMLXGeneration?

  mutating func register(id: MLXGenerationID, task: Task<Void, Never>) {
    activeGeneration = ActiveMLXGeneration(id: id, task: task)
  }

  mutating func beginOrJoinDrain() -> ActiveMLXGeneration? {
    if let drainingGeneration {
      return drainingGeneration
    }
    guard let activeGeneration else {
      return nil
    }
    self.activeGeneration = nil
    activeGeneration.task.cancel()
    drainingGeneration = activeGeneration
    return activeGeneration
  }

  @discardableResult
  mutating func finishDrainIfCurrent(_ generationID: MLXGenerationID) -> Bool {
    guard drainingGeneration?.id == generationID else {
      return false
    }
    drainingGeneration = nil
    return true
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
