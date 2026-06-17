import Foundation

public struct WorkspacePathSuggestionResolver: Sendable {
  private struct Candidate: Sendable {
    var path: WorkspaceRelativePath
    var score: Double
    var reasons: [String]
  }

  private let maxScannedFiles: Int
  private let skippedNames: Set<String>

  public init(
    maxScannedFiles: Int = 1_000,
    skippedNames: Set<String> = WorkspaceFileEnumeration.skippedNames
  ) {
    self.maxScannedFiles = maxScannedFiles
    self.skippedNames = skippedNames
  }

  public func suggestions(
    forMissingPath inputPath: String,
    workspace: Workspace,
    maxSuggestions: Int = 5
  ) -> [MissingPathSuggestion] {
    let requested = RequestedPath(inputPath)
    guard maxSuggestions > 0, !requested.path.isEmpty else {
      return []
    }

    var candidates: [Candidate] = []
    var scannedFiles = 0

    do {
      try WorkspaceFileEnumeration.enumerateFiles(
        at: workspace.rootURL,
        skippedNames: skippedNames
      ) { _, relativePath in
        scannedFiles += 1
        if let candidate = Self.candidate(for: relativePath, requested: requested) {
          candidates.append(candidate)
        }
        return scannedFiles < maxScannedFiles
      }
    } catch {
      return []
    }

    return
      candidates
      .sorted { lhs, rhs in
        if lhs.score != rhs.score {
          return lhs.score > rhs.score
        }
        return lhs.path.rawValue.localizedStandardCompare(rhs.path.rawValue) == .orderedAscending
      }
      .prefix(maxSuggestions)
      .map { candidate in
        MissingPathSuggestion(
          path: candidate.path,
          reason: candidate.reasons.joined(separator: ", "),
          confidence: candidate.score
        )
      }
  }

  private static func candidate(for relativePath: String, requested: RequestedPath) -> Candidate? {
    let candidateDirectory = directoryString(for: relativePath)
    let candidateBase = ((relativePath as NSString).deletingPathExtension as NSString)
      .lastPathComponent.lowercased()
    let candidateExtension = (relativePath as NSString).pathExtension.lowercased()
    let candidatePath = relativePath.lowercased()

    var score = 0.0
    var reasons: [String] = []

    if !requested.directory.isEmpty, candidateDirectory.lowercased() == requested.directory {
      score += 0.45
      reasons.append("same directory")
    }

    if !requested.fileExtension.isEmpty, candidateExtension == requested.fileExtension {
      score += 0.30
      reasons.append("same extension")
    }

    if candidateBase == requested.baseName {
      score += 0.50
      reasons.append("same basename")
    } else if candidateBase.hasPrefix(requested.baseName)
      || requested.baseName.hasPrefix(candidateBase)
    {
      score += 0.30
      reasons.append("similar basename")
    } else if candidateBase.contains(requested.baseName)
      || requested.baseName.contains(candidateBase)
    {
      score += 0.20
      reasons.append("similar basename")
    } else if sharesToken(candidateBase, requested.baseName) {
      score += 0.12
      reasons.append("similar basename")
    }

    if candidatePath.contains(requested.path) || requested.path.contains(candidatePath) {
      score += 0.10
      if !reasons.contains("similar path") {
        reasons.append("similar path")
      }
    }

    guard score > 0, !reasons.isEmpty else {
      return nil
    }

    return Candidate(
      path: WorkspaceRelativePath(rawValue: relativePath),
      score: min(score, 1.0),
      reasons: reasons
    )
  }

  private static func sharesToken(_ lhs: String, _ rhs: String) -> Bool {
    let lhsTokens = Set(tokens(in: lhs))
    guard !lhsTokens.isEmpty else {
      return false
    }
    return tokens(in: rhs).contains { lhsTokens.contains($0) }
  }

  private static func tokens(in value: String) -> [String] {
    value
      .split { !$0.isLetter && !$0.isNumber }
      .map(String.init)
      .filter { $0.count >= 3 }
  }

  private static func directoryString(for relativePath: String) -> String {
    let directory = (relativePath as NSString).deletingLastPathComponent
    return directory == "." ? "" : directory.lowercased()
  }
}

private struct RequestedPath: Sendable {
  var path: String
  var directory: String
  var baseName: String
  var fileExtension: String

  init(_ inputPath: String) {
    let normalized = inputPath.trimmingCharacters(in: .whitespacesAndNewlines)
    let directory = (normalized as NSString).deletingLastPathComponent
    path = normalized.lowercased()
    self.directory = directory == "." ? "" : directory.lowercased()
    baseName = ((normalized as NSString).deletingPathExtension as NSString).lastPathComponent
      .lowercased()
    fileExtension = (normalized as NSString).pathExtension.lowercased()
  }
}
