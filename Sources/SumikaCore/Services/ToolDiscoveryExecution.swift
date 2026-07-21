import Foundation

internal enum WorkspaceFileEnumeration {
  package static let skippedNames: Set<String> = [
    ".git", "DerivedData", ".build", "build", ".swiftpm", "node_modules",
  ]

  package static func enumerateFiles(
    at rootURL: URL,
    relativeTo relativeRootURL: URL? = nil,
    skippedNames: Set<String>,
    visit: (URL, String) throws -> Bool
  ) throws {
    guard !skippedNames.contains(rootURL.lastPathComponent) else {
      return
    }

    let rootPath = Workspace.normalizedPath(for: relativeRootURL ?? rootURL)
    _ = try enumerateFiles(
      at: rootURL,
      rootPath: rootPath,
      skippedNames: skippedNames,
      visit: visit
    )
  }

  private static func enumerateFiles(
    at directoryURL: URL,
    rootPath: String,
    skippedNames: Set<String>,
    visit: (URL, String) throws -> Bool
  ) throws -> Bool {
    let children = try FileManager.default.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
      options: [.skipsPackageDescendants]
    )
    .sorted { lhs, rhs in
      lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
    }

    for child in children {
      let name = child.lastPathComponent
      let resourceValues = try child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
      if resourceValues.isDirectory == true {
        guard !skippedNames.contains(name) else {
          continue
        }

        guard
          try enumerateFiles(
            at: child,
            rootPath: rootPath,
            skippedNames: skippedNames,
            visit: visit
          )
        else {
          return false
        }
        continue
      }

      guard resourceValues.isRegularFile == true else {
        continue
      }

      let filePath = Workspace.normalizedPath(for: child)
      let relativePath =
        filePath.hasPrefix(rootPath + "/")
        ? String(filePath.dropFirst(rootPath.count + 1))
        : name

      guard try visit(child, relativePath) else {
        return false
      }
    }

    return true
  }
}

internal struct GlobPatternMatcher {
  private let regex: NSRegularExpression

  package init(pattern: String) throws {
    regex = try NSRegularExpression(pattern: Self.regularExpressionPattern(for: pattern))
  }

  package func matches(_ value: String) -> Bool {
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    return regex.firstMatch(in: value, range: range) != nil
  }

  private static func regularExpressionPattern(for pattern: String) -> String {
    var output = "^"
    var index = pattern.startIndex

    while index < pattern.endIndex {
      let character = pattern[index]
      let nextIndex = pattern.index(after: index)

      if character == "*" {
        if nextIndex < pattern.endIndex, pattern[nextIndex] == "*" {
          let afterGlobstar = pattern.index(after: nextIndex)
          if afterGlobstar < pattern.endIndex, pattern[afterGlobstar] == "/" {
            output += "(?:.*/)?"
            index = pattern.index(after: afterGlobstar)
          } else {
            output += ".*"
            index = afterGlobstar
          }
        } else {
          output += "[^/]*"
          index = nextIndex
        }
      } else if character == "?" {
        output += "[^/]"
        index = nextIndex
      } else {
        output += NSRegularExpression.escapedPattern(for: String(character))
        index = nextIndex
      }
    }

    return output + "$"
  }
}

internal struct SearchPattern {
  private let regex: NSRegularExpression?
  private let literal: String

  package init(pattern: String) {
    regex = try? NSRegularExpression(pattern: pattern)
    literal = pattern
  }

  package func matches(_ line: String) -> Bool {
    if let regex {
      return regex.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line))
        != nil
    }

    return line.contains(literal)
  }
}
