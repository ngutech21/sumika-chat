import Foundation

nonisolated struct ChatContextUsage: Equatable, Sendable {
    let usedTokens: Int
    let tokenLimit: Int?

    var availableTokens: Int? {
        guard let tokenLimit else {
            return nil
        }

        return max(tokenLimit - usedTokens, 0)
    }

    var summary: String {
        guard let tokenLimit else {
            return "\(usedTokens) tokens"
        }

        return "\(usedTokens)/\(tokenLimit) tokens"
    }

    var fraction: Double? {
        guard let tokenLimit, tokenLimit > 0 else {
            return nil
        }

        return min(Double(usedTokens) / Double(tokenLimit), 1)
    }
}
