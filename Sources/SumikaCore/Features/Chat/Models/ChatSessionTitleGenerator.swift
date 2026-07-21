import Foundation

enum ChatSessionTitleGenerator {
  static let maximumLength = 48

  static func title(fromFirstPrompt prompt: String) -> String {
    let normalized =
      prompt
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")

    guard !normalized.isEmpty else {
      return ChatSession.defaultTitle
    }

    if normalized.count <= maximumLength {
      return normalized
    }

    let limitIndex = normalized.index(normalized.startIndex, offsetBy: maximumLength)
    let prefix = String(normalized[..<limitIndex])
    let wordBoundaryPrefix =
      prefix.range(of: " ", options: .backwards).map { String(prefix[..<$0.lowerBound]) }
      ?? prefix
    let trimmed = wordBoundaryPrefix.trimmingCharacters(in: .whitespacesAndNewlines)

    return trimmed.isEmpty ? prefix : trimmed
  }
}
