import Foundation

public enum ToolNameRepairMethod: String, Codable, Equatable, Sendable {
  case caseFold
  case separator
  case camelCase

}

public enum ToolNameResolution: Equatable, Sendable {
  case exact(ToolName)
  case repaired(original: String, canonical: ToolName, method: ToolNameRepairMethod)
  case unknown(original: String)
  case ambiguous(original: String, candidates: [ToolName])

  public var canonicalToolName: ToolName? {
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

public struct ToolNameResolver: Sendable {

  public func resolve(_ rawName: String, registry: ToolRegistry) -> ToolNameResolution {
    let original = rawName
    let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    let exact = ToolName(rawValue: trimmed)
    if registry.definition(for: exact) != nil {
      return .exact(exact)
    }

    var candidates: [ToolName: ToolNameRepairMethod] = [:]
    collectCandidate(
      method: .caseFold,
      repairedName: trimmed.lowercased(),
      registry: registry,
      candidates: &candidates
    )
    collectCandidate(
      method: .separator,
      repairedName: separatorRepaired(trimmed),
      registry: registry,
      candidates: &candidates
    )
    collectCandidate(
      method: .camelCase,
      repairedName: camelCaseRepaired(trimmed),
      registry: registry,
      candidates: &candidates
    )

    let sortedCandidates = candidates.keys.sorted { $0.rawValue < $1.rawValue }
    guard let canonical = sortedCandidates.first else {
      return .unknown(original: original)
    }
    guard sortedCandidates.count == 1 else {
      return .ambiguous(original: original, candidates: sortedCandidates)
    }
    return .repaired(
      original: original,
      canonical: canonical,
      method: candidates[canonical] ?? .caseFold
    )
  }

  private func collectCandidate(
    method: ToolNameRepairMethod,
    repairedName: String,
    registry: ToolRegistry,
    candidates: inout [ToolName: ToolNameRepairMethod]
  ) {
    let candidate = ToolName(rawValue: repairedName)
    guard registry.definition(for: candidate) != nil else {
      return
    }
    if candidates[candidate] == nil {
      candidates[candidate] = method
    }
  }

  private func separatorRepaired(_ name: String) -> String {
    name
      .replacingOccurrences(of: "-", with: "_")
      .replacingOccurrences(of: " ", with: "_")
      .lowercased()
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
