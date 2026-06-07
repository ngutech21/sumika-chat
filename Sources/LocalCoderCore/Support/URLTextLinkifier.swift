import Foundation

public enum URLTextLinkifier {
  public static func attributedString(for text: String) -> AttributedString {
    var attributedText = AttributedString(text)

    for link in links(in: text) {
      guard
        let lowerBound = AttributedString.Index(link.range.lowerBound, within: attributedText),
        let upperBound = AttributedString.Index(link.range.upperBound, within: attributedText)
      else {
        continue
      }

      attributedText[lowerBound..<upperBound].link = link.url
    }

    return attributedText
  }

  public static func links(in text: String) -> [DetectedURLTextLink] {
    guard !text.isEmpty else {
      return []
    }

    let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s<>\"]+"#) else {
      return []
    }

    return regex.matches(in: text, options: [], range: nsRange).compactMap { match in
      guard let candidateRange = Range(match.range, in: text) else {
        return nil
      }

      let sanitizedRange = sanitizedURLRange(candidateRange, in: text)
      guard !sanitizedRange.isEmpty else {
        return nil
      }

      let rawURL = String(text[sanitizedRange])
      guard
        let url = URL(string: rawURL),
        let scheme = url.scheme?.lowercased(),
        scheme == "http" || scheme == "https"
      else {
        return nil
      }

      return DetectedURLTextLink(url: url, range: sanitizedRange)
    }
  }

  private static func sanitizedURLRange(
    _ range: Range<String.Index>,
    in text: String
  ) -> Range<String.Index> {
    var upperBound = range.upperBound

    while range.lowerBound < upperBound {
      let lastIndex = text.index(before: upperBound)
      let lastCharacter = text[lastIndex]

      if isTrailingPunctuation(lastCharacter)
        || isUnbalancedClosingDelimiter(lastCharacter, in: text[range.lowerBound..<upperBound])
      {
        upperBound = lastIndex
      } else {
        break
      }
    }

    return range.lowerBound..<upperBound
  }

  private static func isTrailingPunctuation(_ character: Character) -> Bool {
    switch character {
    case ".", ",", ";", ":", "!", "?":
      true
    default:
      false
    }
  }

  private static func isUnbalancedClosingDelimiter(
    _ character: Character,
    in text: Substring
  ) -> Bool {
    let openingDelimiter: Character
    switch character {
    case ")":
      openingDelimiter = "("
    case "]":
      openingDelimiter = "["
    case "}":
      openingDelimiter = "{"
    default:
      return false
    }

    let openingCount = text.reduce(into: 0) { count, currentCharacter in
      if currentCharacter == openingDelimiter {
        count += 1
      }
    }
    let closingCount = text.reduce(into: 0) { count, currentCharacter in
      if currentCharacter == character {
        count += 1
      }
    }
    return closingCount > openingCount
  }
}

public struct DetectedURLTextLink: Equatable {
  public let url: URL
  public let range: Range<String.Index>

  public init(url: URL, range: Range<String.Index>) {
    self.url = url
    self.range = range
  }
}
