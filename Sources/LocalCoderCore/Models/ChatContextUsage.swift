import Foundation

public struct ChatContextUsage: Equatable, Sendable {
  public let usedTokens: Int
  public let tokenLimit: Int?

  public init(usedTokens: Int, tokenLimit: Int?) {
    self.usedTokens = usedTokens
    self.tokenLimit = tokenLimit
  }

  public var availableTokens: Int? {
    guard let tokenLimit else {
      return nil
    }

    return max(tokenLimit - usedTokens, 0)
  }

  public var summary: String {
    guard let tokenLimit else {
      return "\(usedTokens) tokens"
    }

    return "\(usedTokens)/\(tokenLimit) tokens"
  }

  public var fraction: Double? {
    guard let tokenLimit, tokenLimit > 0 else {
      return nil
    }

    return min(Double(usedTokens) / Double(tokenLimit), 1)
  }
}
