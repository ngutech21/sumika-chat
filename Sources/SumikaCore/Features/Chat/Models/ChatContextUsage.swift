import Foundation

public enum ChatContextUsageAccuracy: String, Equatable, Sendable {
  case estimate
  case exact
}

public struct ChatContextUsage: Equatable, Sendable {
  public let usedTokens: Int
  public let tokenLimit: Int?
  public let accuracy: ChatContextUsageAccuracy
  public let isStale: Bool

  public init(
    usedTokens: Int,
    tokenLimit: Int?,
    accuracy: ChatContextUsageAccuracy = .exact,
    isStale: Bool = false
  ) {
    self.usedTokens = usedTokens
    self.tokenLimit = tokenLimit
    self.accuracy = accuracy
    self.isStale = isStale
  }

  public var availableTokens: Int? {
    guard let tokenLimit else {
      return nil
    }

    return max(tokenLimit - usedTokens, 0)
  }

  public var summary: String {
    let prefix = accuracy == .estimate ? "~" : ""
    guard let tokenLimit else {
      return "\(prefix)\(usedTokens) tokens"
    }

    return "\(prefix)\(usedTokens)/\(tokenLimit) tokens"
  }

  public var fraction: Double? {
    guard let tokenLimit, tokenLimit > 0 else {
      return nil
    }

    return min(Double(usedTokens) / Double(tokenLimit), 1)
  }
}

/// Point-in-time input for the context-usage estimate: the transcript, prompt,
/// and attachments the next generation would send, plus the model state that
/// gates whether an estimate is meaningful at all.
public struct ContextUsageSnapshot: Sendable {
  public let modelState: ModelLoadState
  public let transcript: ModelPromptProjection
  public let attachments: [ChatAttachment]
  public let systemPrompt: String
  public let contextTokenLimit: Int?

  public init(
    modelState: ModelLoadState,
    transcript: ModelPromptProjection,
    attachments: [ChatAttachment],
    systemPrompt: String,
    contextTokenLimit: Int? = nil
  ) {
    self.modelState = modelState
    self.transcript = transcript
    self.attachments = attachments
    self.systemPrompt = systemPrompt
    self.contextTokenLimit = contextTokenLimit
  }

  public func estimatedUsage(isStale: Bool = true) -> ChatContextUsage {
    var byteCount = systemPrompt.utf8.count
    // `.fullHistory` projects every entry to its `frozenContent.content` verbatim,
    // so we sum the stored content directly instead of allocating a projected array.
    for entry in transcript.entries {
      byteCount += entry.frozenContent.content.utf8.count
    }
    for attachment in attachments {
      guard attachment.kind == .text else {
        continue
      }
      byteCount += attachment.content.utf8.count
    }

    return ChatContextUsage(
      usedTokens: Int(ceil(Double(byteCount) / 4.0)),
      tokenLimit: contextTokenLimit,
      accuracy: .estimate,
      isStale: isStale
    )
  }
}
