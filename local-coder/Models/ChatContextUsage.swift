import Foundation

struct ChatContextUsage: Equatable, Sendable {
    let usedTokens: Int
    let tokenLimit: Int?

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
