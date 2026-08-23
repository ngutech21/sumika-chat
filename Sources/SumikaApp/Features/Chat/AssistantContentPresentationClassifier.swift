import Foundation
import Markdown
import SumikaCore

enum AssistantContentPresentation: Equatable {
  case markdown
  case rawCode(CodeLanguage)
}

enum AssistantContentPresentationClassifier {
  static func classify(_ content: String) -> AssistantContentPresentation {
    let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedContent.isEmpty else {
      return .markdown
    }

    if isJSONObjectOrArray(trimmedContent) {
      return .rawCode(.json)
    }

    if isHTMLDocument(trimmedContent) {
      return .rawCode(.html)
    }

    if let language = shebangLanguage(trimmedContent) {
      return .rawCode(language)
    }

    if hasStrongMarkdownStructure(trimmedContent) {
      return .markdown
    }

    if looksLikeShellDocument(trimmedContent) {
      return .rawCode(.bash)
    }

    if looksLikeTypeScriptDocument(trimmedContent) {
      return .rawCode(.typescript)
    }

    if looksLikePythonDocument(trimmedContent) {
      return .rawCode(.python)
    }

    if looksLikeCSSDocument(trimmedContent) {
      return .rawCode(.css)
    }

    return .markdown
  }

  private static func hasStrongMarkdownStructure(_ content: String) -> Bool {
    containsStrongMarkdownStructure(in: Document(parsing: content))
  }

  private static func containsStrongMarkdownStructure(in markup: Markup) -> Bool {
    if markup is Heading || markup is Table || markup is UnorderedList
      || markup is OrderedList || markup is BlockQuote || markup is ThematicBreak
    {
      return true
    }
    return markup.children.contains { containsStrongMarkdownStructure(in: $0) }
  }

  private static func looksLikeShellDocument(_ content: String) -> Bool {
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    var hasStructure = false
    var hasCommand = false

    for line in lines {
      if line.hasPrefix("#") {
        continue
      }
      if matches(#"^(?:(?:for|while|until)\b.*;\s*do|if\b.*;\s*then|case\b.*\bin)$"#, in: line)
        || matches(#"^[A-Za-z_][A-Za-z0-9_]*=.*$"#, in: line)
      {
        hasStructure = true
      } else if matches(#"^(?:done|fi|esac)$"#, in: line) {
        continue
      } else if matches(
        #"^(?:echo|printf|cd|git|just|mkdir|rm|cp|mv|cat|sed|awk|grep|find|curl|swift|xcodebuild)\b"#,
        in: line
      ) {
        hasCommand = true
      } else {
        return false
      }
    }

    return hasStructure && hasCommand
  }

  private static func looksLikeCSSDocument(_ content: String) -> Bool {
    if matches(
      #"(?s)^\s*(?:(?:/\*.*?\*/\s*)?(?:[.#]?[A-Za-z][A-Za-z0-9_-]*|\*|:root|@[A-Za-z-]+)[^{;]*\{\s*(?:-{0,2}[A-Za-z][A-Za-z0-9-]*\s*:\s*[^;{}]+;\s*)+\}\s*)+$"#,
      in: content
    ) {
      return true
    }

    return matches(
      #"(?s)^\s*(?:(?:/\*.*?\*/\s*)?@[A-Za-z-]+[^{;]*\{\s*(?:(?:/\*.*?\*/\s*)?(?:[.#]?[A-Za-z][A-Za-z0-9_-]*|\*|:root|\d+(?:\.\d+)?%)[^{;]*\{\s*(?:-{0,2}[A-Za-z][A-Za-z0-9-]*\s*:\s*[^;{}]+;\s*)+\}\s*)+\}\s*)+$"#,
      in: content
    )
  }

  private static func looksLikePythonDocument(_ content: String) -> Bool {
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
    let hasBlockAnchor = lines.contains { line in
      let trimmedLine = line.trimmingCharacters(in: .whitespaces)
      return matches(
        #"^(?:async\s+def|def|class)\s+[A-Za-z_][A-Za-z0-9_]*.*:\s*$"#, in: trimmedLine)
        || trimmedLine.hasPrefix("if __name__ == ") && trimmedLine.hasSuffix(":")
    }
    let hasIndentedBody = lines.contains { line in
      guard line.first == " " || line.first == "\t" else {
        return false
      }
      let trimmedLine = line.trimmingCharacters(in: .whitespaces)
      return !trimmedLine.isEmpty && !trimmedLine.hasPrefix("#")
    }
    let hasImport = lines.contains { line in
      let trimmedLine = line.trimmingCharacters(in: .whitespaces)
      return matches(
        #"^(?:import\s+[A-Za-z_][A-Za-z0-9_.]*|from\s+[A-Za-z_][A-Za-z0-9_.]*\s+import\s+)"#,
        in: trimmedLine)
    }
    let hasAdditionalStatement = lines.contains { line in
      let trimmedLine = line.trimmingCharacters(in: .whitespaces)
      return matches(#"^[A-Za-z_][A-Za-z0-9_]*\s*=.+$"#, in: trimmedLine)
        || matches(#"^[A-Za-z_][A-Za-z0-9_.]*\(.*\)\s*$"#, in: trimmedLine)
    }
    return hasBlockAnchor && hasIndentedBody || hasImport && hasAdditionalStatement
  }

  private static func looksLikeTypeScriptDocument(_ content: String) -> Bool {
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }

    return lines.contains { line in
      if matches(
        #"^(?:(?:export|declare)\s+)*type\s+[A-Za-z_$][A-Za-z0-9_$]*(?:\s*<[^>]+>)?\s*="#,
        in: line
      ) {
        return true
      }

      if matches(
        #"^(?:(?:export|declare)\s+)*(?:const|let|var)\s+[A-Za-z_$][A-Za-z0-9_$]*\??\s*:\s*[A-Za-z_$][A-Za-z0-9_$<>\[\]|&.,? ]*\s*(?:=|$)"#,
        in: line
      ) {
        return true
      }

      guard
        matches(
          #"^(?:(?:export|declare)\s+)*(?:interface|enum|class|function|const|let|var|import)\b"#,
          in: line
        )
      else {
        return false
      }
      return matches(#"[{};]|=>"#, in: line)
    }
  }

  private static func matches(_ pattern: String, in content: String) -> Bool {
    content.range(of: pattern, options: .regularExpression) != nil
  }

  private static func shebangLanguage(_ content: String) -> CodeLanguage? {
    guard let firstLine = content.split(separator: "\n", maxSplits: 1).first,
      firstLine.hasPrefix("#!"),
      let executable = firstLine.dropFirst(2).split(whereSeparator: \Character.isWhitespace).first
    else {
      return nil
    }

    let executableName = executable.split(separator: "/").last?.lowercased()
    let interpreter: String?
    if executableName == "env" {
      interpreter = firstLine.dropFirst(2)
        .split(whereSeparator: \Character.isWhitespace)
        .dropFirst()
        .first { !$0.hasPrefix("-") }?
        .split(separator: "/").last?
        .lowercased()
    } else {
      interpreter = executableName
    }

    guard let interpreter else {
      return nil
    }

    switch interpreter {
    case "bash", "sh", "zsh":
      return .bash
    case "python", "python3":
      return .python
    default:
      return interpreter.hasPrefix("python3.") ? .python : nil
    }
  }

  private static func isHTMLDocument(_ content: String) -> Bool {
    let lowercasedContent = content.lowercased()
    return
      (lowercasedContent.hasPrefix("<!doctype html")
      || lowercasedContent.hasPrefix("<html"))
      && lowercasedContent.contains("</html>")
  }

  private static func isJSONObjectOrArray(_ content: String) -> Bool {
    guard let firstCharacter = content.first,
      let lastCharacter = content.last,
      (firstCharacter == "{" && lastCharacter == "}")
        || (firstCharacter == "[" && lastCharacter == "]")
    else {
      return false
    }

    return (try? JSONSerialization.jsonObject(with: Data(content.utf8))) != nil
  }
}
