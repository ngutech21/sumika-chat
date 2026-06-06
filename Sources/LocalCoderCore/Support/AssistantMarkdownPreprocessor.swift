import Foundation

public enum AssistantMarkdownPreprocessor {
  public static func renderableContent(for content: String) -> String {
    let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !content.contains("```") else {
      return content
    }

    if let legacyFileDisplay = normalizedLegacyDirectFileDisplay(content) {
      return legacyFileDisplay
    }

    guard !trimmedContent.isEmpty,
      let language = inferredCodeLanguage(for: trimmedContent)
    else {
      return content
    }

    return """
      ```\(language)
      \(trimmedContent)
      ```
      """
  }

  private static func normalizedLegacyDirectFileDisplay(_ content: String) -> String? {
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard
      let firstLine = lines.first?.trimmingCharacters(in: .whitespaces),
      firstLine.hasPrefix("Here is `"),
      firstLine.hasSuffix("`:"),
      let path = legacyDirectFileDisplayPath(from: firstLine)
    else {
      return nil
    }

    var bodyStartIndex = 1
    while bodyStartIndex < lines.count && lines[bodyStartIndex].isEmpty {
      bodyStartIndex += 1
    }

    guard bodyStartIndex < lines.count, lines[bodyStartIndex].hasPrefix("    ") else {
      return nil
    }

    var bodyLines: [String] = []
    var suffixStartIndex = bodyStartIndex
    while suffixStartIndex < lines.count, lines[suffixStartIndex].hasPrefix("    ") {
      bodyLines.append(String(lines[suffixStartIndex].dropFirst(4)))
      suffixStartIndex += 1
    }

    guard !bodyLines.isEmpty else {
      return nil
    }

    let body = bodyLines.joined(separator: "\n")
    let fence = markdownFence(for: body)
    let language = CodeLanguage(filePath: path)?.rawValue ?? ""
    let openingFence = language.isEmpty ? fence : "\(fence)\(language)"
    var normalized = "\(firstLine)\n\n\(openingFence)\n\(body)"
    if !normalized.hasSuffix("\n") {
      normalized += "\n"
    }
    normalized += fence

    if suffixStartIndex < lines.count {
      normalized += "\n"
      normalized += lines[suffixStartIndex...].joined(separator: "\n")
    }

    return normalized
  }

  private static func legacyDirectFileDisplayPath(from firstLine: String) -> String? {
    guard
      let firstBacktick = firstLine.firstIndex(of: "`"),
      let lastBacktick = firstLine.lastIndex(of: "`"),
      firstBacktick < lastBacktick
    else {
      return nil
    }

    let pathStart = firstLine.index(after: firstBacktick)
    return String(firstLine[pathStart..<lastBacktick])
  }

  private static func markdownFence(for body: String) -> String {
    var longestRun = 0
    var currentRun = 0

    for character in body {
      if character == "`" {
        currentRun += 1
        longestRun = max(longestRun, currentRun)
      } else {
        currentRun = 0
      }
    }

    return String(repeating: "`", count: max(3, longestRun + 1))
  }

  private static func inferredCodeLanguage(for content: String) -> String? {
    guard !looksLikeMarkdownNarrative(content) else {
      return nil
    }

    let lowercasedContent = content.lowercased()

    if lowercasedContent.hasPrefix("<!doctype")
      || lowercasedContent.hasPrefix("<html")
      || lowercasedContent.contains("</html>")
    {
      return "html"
    }

    if looksLikeJSON(content) {
      return "json"
    }

    if looksLikeSwift(content) {
      return "swift"
    }

    if looksLikeShell(content) {
      return "bash"
    }

    if looksLikeCSS(content) {
      return "css"
    }

    return nil
  }

  private static func looksLikeMarkdownNarrative(_ content: String) -> Bool {
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces) }
    guard let firstNonEmptyLine = lines.first(where: { !$0.isEmpty }) else {
      return false
    }

    return firstNonEmptyLine.contains("`")
      || firstNonEmptyLine.hasPrefix("# ")
      || firstNonEmptyLine.hasPrefix("- ")
      || firstNonEmptyLine.hasPrefix("* ")
  }

  private static func looksLikeJSON(_ content: String) -> Bool {
    guard let firstCharacter = content.first,
      let lastCharacter = content.last,
      (firstCharacter == "{" && lastCharacter == "}")
        || (firstCharacter == "[" && lastCharacter == "]")
    else {
      return false
    }

    return (try? JSONSerialization.jsonObject(with: Data(content.utf8))) != nil
  }

  private static func looksLikeSwift(_ content: String) -> Bool {
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces) }

    return lines.contains { line in
      line.hasPrefix("import ")
        || line.hasPrefix("func ")
        || line.hasPrefix("struct ")
        || line.hasPrefix("class ")
        || line.hasPrefix("enum ")
        || line.hasPrefix("let ")
        || line.hasPrefix("var ")
    }
  }

  private static func looksLikeShell(_ content: String) -> Bool {
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces) }

    return lines.contains { line in
      line.hasPrefix("#!/bin/")
        || line.hasPrefix("$ ")
        || line.hasPrefix("cd ")
        || line.hasPrefix("mkdir ")
        || line.hasPrefix("git ")
        || line.hasPrefix("just ")
    }
  }

  private static func looksLikeCSS(_ content: String) -> Bool {
    content.contains("{")
      && content.contains("}")
      && content.contains(":")
      && (content.contains(";") || content.contains("}"))
  }
}
