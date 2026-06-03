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
