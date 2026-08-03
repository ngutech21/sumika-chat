import Foundation

enum ToolIdentifierRepairMethod: String, Codable, Equatable, Sendable, CaseIterable {
  case caseFold
  case separator
  case camelCase
}

enum ToolIdentifierResolution: Equatable, Sendable {
  case exact(String)
  case repaired(original: String, canonical: String, method: ToolIdentifierRepairMethod)
  case unknown(original: String)
  case ambiguous(original: String, candidates: [String])

  var canonicalName: String? {
    switch self {
    case .exact(let name):
      name
    case .repaired(_, let canonical, _):
      canonical
    case .unknown, .ambiguous:
      nil
    }
  }
}

struct ToolIdentifierResolver: Sendable {
  func resolve(_ rawName: String, candidates: some Sequence<String>) -> ToolIdentifierResolution {
    let original = rawName
    let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    let canonicalNames = Set(candidates)
    if canonicalNames.contains(trimmed) {
      return .exact(trimmed)
    }

    var matches: [String: ToolIdentifierRepairMethod] = [:]
    for method in ToolIdentifierRepairMethod.allCases {
      let repairedName = normalized(trimmed, method: method)
      for candidate in canonicalNames
      where normalized(candidate, method: method) == repairedName && matches[candidate] == nil {
        matches[candidate] = method
      }
    }

    let sortedCandidates = matches.keys.sorted()
    guard let canonical = sortedCandidates.first else {
      return .unknown(original: original)
    }
    guard sortedCandidates.count == 1 else {
      return .ambiguous(original: original, candidates: sortedCandidates)
    }
    return .repaired(
      original: original,
      canonical: canonical,
      method: matches[canonical] ?? .caseFold
    )
  }

  private func normalized(_ name: String, method: ToolIdentifierRepairMethod) -> String {
    switch method {
    case .caseFold:
      name.lowercased()
    case .separator:
      name
        .replacingOccurrences(of: "-", with: "_")
        .replacingOccurrences(of: " ", with: "_")
        .lowercased()
    case .camelCase:
      camelCaseRepaired(name)
    }
  }

  private func camelCaseRepaired(_ name: String) -> String {
    var output = ""
    var previousWasSeparator = true

    for scalar in name.unicodeScalars {
      let character = Character(scalar)
      if CharacterSet.uppercaseLetters.contains(scalar) {
        if !previousWasSeparator {
          output.append("_")
        }
        output.append(String(character).lowercased())
        previousWasSeparator = false
      } else if CharacterSet(charactersIn: "- ").contains(scalar) {
        if !output.hasSuffix("_") {
          output.append("_")
        }
        previousWasSeparator = true
      } else {
        output.append(String(character).lowercased())
        previousWasSeparator = scalar == "_"
      }
    }

    return output
  }
}

enum ToolNameResolution: Equatable, Sendable {
  case exact(ToolName)
  case repaired(original: String, canonical: ToolName, method: ToolIdentifierRepairMethod)
  case unknown(original: String)
  case ambiguous(original: String, candidates: [ToolName])

  var canonicalToolName: ToolName? {
    switch self {
    case .exact(let toolName):
      toolName
    case .repaired(_, let canonical, _):
      canonical
    case .unknown, .ambiguous:
      nil
    }
  }
}

struct ToolNameResolver: Sendable {
  func resolve(_ rawName: String, registry: ToolRegistry) -> ToolNameResolution {
    let resolution = ToolIdentifierResolver().resolve(
      rawName,
      candidates: registry.tools.map(\.name.rawValue)
    )
    switch resolution {
    case .exact(let canonical):
      return .exact(ToolName(rawValue: canonical))
    case .repaired(let original, let canonical, let method):
      return .repaired(
        original: original,
        canonical: ToolName(rawValue: canonical),
        method: method
      )
    case .unknown(let original):
      return .unknown(original: original)
    case .ambiguous(let original, let candidates):
      return .ambiguous(
        original: original,
        candidates: candidates.map { ToolName(rawValue: $0) }
      )
    }
  }
}
