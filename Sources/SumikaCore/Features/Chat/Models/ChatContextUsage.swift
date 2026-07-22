// Foundation provides ceil; the analyzer compiler log does not attribute it reliably.
// swiftlint:disable:next unused_import
import Foundation

package enum ChatContextUsageAccuracy: String, Equatable, Sendable {
  case estimate
  case exact
}

package struct ChatContextUsage: Equatable, Sendable {
  package let usedTokens: Int
  package let tokenLimit: Int?
  package let accuracy: ChatContextUsageAccuracy
  package let isStale: Bool

  package init(
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

  // Test-only; exercised through @testable import.
  // swiftlint:disable:next unused_declaration
  package var availableTokens: Int? {
    guard let tokenLimit else {
      return nil
    }

    return max(tokenLimit - usedTokens, 0)
  }

  // Test-only; exercised through @testable import.
  // swiftlint:disable:next unused_declaration
  package var summary: String {
    let prefix = accuracy == .estimate ? "~" : ""
    guard let tokenLimit else {
      return "\(prefix)\(usedTokens) tokens"
    }

    return "\(prefix)\(usedTokens)/\(tokenLimit) tokens"
  }

  package var fraction: Double? {
    guard let tokenLimit, tokenLimit > 0 else {
      return nil
    }

    return min(Double(usedTokens) / Double(tokenLimit), 1)
  }
}

/// Point-in-time input for the context-usage estimate: the transcript, prompt,
/// and attachments the next generation would send, plus the model state that
/// gates whether an estimate is meaningful at all.
package struct ContextUsageSnapshot: Sendable {
  package let modelState: ModelLoadState
  package let transcript: ModelPromptProjection
  package let attachments: [ChatAttachment]
  package let systemPrompt: String
  package let contextTokenLimit: Int?

  package init(
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

  package func estimatedUsage(isStale: Bool = true) -> ChatContextUsage {
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
