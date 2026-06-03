import Foundation

public enum AssistantMarkdownPreprocessor {
  public static func renderableContent(for content: String) -> String {
    let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !trimmedContent.isEmpty,
      !content.contains("```"),
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

  private static func inferredCodeLanguage(for content: String) -> String? {
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
