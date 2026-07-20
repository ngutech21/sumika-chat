import Foundation

package enum CodeLanguage: String, CaseIterable, Equatable, Hashable, Sendable {
  case bash
  case css
  case html
  case javascript
  case json
  case python
  case typescript

  package init?(fenceLanguage: String?) {
    guard
      let rawLanguage = fenceLanguage?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased(),
      !rawLanguage.isEmpty
    else {
      return nil
    }

    let normalizedLanguage = rawLanguage.split(whereSeparator: { $0 == " " || $0 == "\t" }).first
      .map(String.init)
    switch normalizedLanguage {
    case "bash", "sh", "shell", "zsh":
      self = .bash
    case "css":
      self = .css
    case "html", "htm":
      self = .html
    case "js", "javascript", "mjs", "cjs":
      self = .javascript
    case "json":
      self = .json
    case "py", "python", "python3":
      self = .python
    case "ts", "typescript":
      self = .typescript
    default:
      return nil
    }
  }

  package init?(filePath: String) {
    let trimmedPath = filePath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedPath.isEmpty else {
      return nil
    }

    let fileName = trimmedPath.split(separator: "/").last.map(String.init) ?? trimmedPath
    guard
      let dotIndex = fileName.lastIndex(of: "."),
      dotIndex < fileName.index(before: fileName.endIndex)
    else {
      return nil
    }

    self.init(fenceLanguage: String(fileName[fileName.index(after: dotIndex)...]))
  }
}
