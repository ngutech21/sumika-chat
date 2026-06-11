import Foundation

public struct RuntimeCacheDebugSnapshot: Equatable, Sendable {
  public let generationID: UUID
  public let recordedAt: Date
  public let cacheMode: String
  public let cacheReason: String
  public let reuseStrategy: String
  public let appendDeltaStartIndex: Int?
  public let contextSignature: String
  public let previousContextSignature: String?
  public let appendOnly: Bool
  public let reusedMessageCount: Int
  public let appendedMessageCount: Int
  public let mismatchReason: String?
  public let firstMismatchIndex: Int?
  public let systemPromptChanged: Bool?
  public let currentPromptContextChanged: Bool?
  public let cacheEligibility: String
  public let cacheEligibilityReason: String?

  public init(
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
    systemPromptChanged: Bool? = nil,
    currentPromptContextChanged: Bool? = nil,
    cacheEligibility: String,
    cacheEligibilityReason: String? = nil
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
    self.currentPromptContextChanged = currentPromptContextChanged
    self.cacheEligibility = cacheEligibility
    self.cacheEligibilityReason = cacheEligibilityReason
  }
}
