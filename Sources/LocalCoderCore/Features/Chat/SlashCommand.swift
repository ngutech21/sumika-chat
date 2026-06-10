import Foundation

public enum SlashCommand: Equatable, Sendable {
  case preview(path: String)
}

public struct SlashCommandParser: Sendable {
  public init() {}

  public func parse(_ input: String) -> SlashCommand? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("/preview") else {
      return nil
    }

    let remainder = trimmed.dropFirst("/preview".count)
    guard remainder.isEmpty || remainder.first?.isWhitespace == true else {
      return nil
    }

    let path = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty else {
      return nil
    }

    return .preview(path: path)
  }
}
