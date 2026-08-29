// Crypto is used directly here; the analyzer compiler log does not attribute it reliably.
// swiftlint:disable:next unused_import
import Crypto
import Foundation
import Yams

package actor SkillCatalog {
  package static let maximumActivatedContentCharacters = 32_000

  private let homeDirectoryURL: URL
  private var scans: [String: Task<CatalogStorage, Never>] = [:]

  package init(
    homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
  ) {
    self.homeDirectoryURL = homeDirectoryURL
  }

  package func refresh(for workspace: Workspace) async -> SkillCatalogSnapshot {
    await loadStorage(for: workspace).snapshot
  }

  package func prepareSubmission(
    _ submission: MessageSubmission,
    mode: WorkspaceInteractionMode,
    workspace: Workspace
  ) async throws -> PreparedSkillSubmission {
    guard mode == .agent else {
      return .empty
    }
    let storage = await loadStorage(for: workspace)
    return try Self.prepare(submission, from: storage)
  }

  func resourceRoots(
    matching activatedSkills: [ActivatedSkill],
    workspace: Workspace
  ) async -> [SkillResourceRoot] {
    let storage = await loadStorage(for: workspace)
    return activatedSkills.compactMap { skill in
      guard let entry = storage.entries[skill.id],
        entry.descriptor.portablePath == skill.portablePath,
        entry.contentHash == skill.contentHash,
        entry.content == skill.content
      else {
        return nil
      }
      return SkillResourceRoot(id: skill.id, rootURL: entry.rootURL)
    }
  }

  private func loadStorage(for workspace: Workspace) async -> CatalogStorage {
    let key = scanKey(for: workspace)
    if let scan = scans[key] {
      return await scan.value
    }

    let homeDirectoryURL = homeDirectoryURL
    let scan = Task.detached(priority: .userInitiated) {
      workspace.withSecurityScopedAccess {
        Self.scan(workspace: workspace, homeDirectoryURL: homeDirectoryURL)
      }
    }
    scans[key] = scan
    let storage = await scan.value
    scans[key] = nil
    return storage
  }

  private func scanKey(for workspace: Workspace) -> String {
    let projectRootPath = workspace.rootURL.standardizedFileURL.path(percentEncoded: false)
    let homeDirectoryPath = homeDirectoryURL.standardizedFileURL.path(percentEncoded: false)
    return projectRootPath + "\u{0}" + homeDirectoryPath
  }
}

extension SkillCatalog {
  fileprivate struct CatalogStorage: Sendable {
    let entries: [SkillID: SkillEntry]
    let snapshot: SkillCatalogSnapshot
  }

  fileprivate struct SkillEntry: Sendable {
    let descriptor: SkillDescriptor
    let rootURL: URL
    let contentHash: String
    let content: String
    let interfaceMetadata: SkillInterfaceMetadata?
  }

  fileprivate struct ScopeScanResult: Sendable {
    var entries: [SkillEntry] = []
    var diagnostics: [SkillDiagnostic] = []
  }

  fileprivate enum SkillDirectoryConvention: String, CaseIterable, Sendable {
    case agents
    case claude
    case cursor

    var relativeSkillsPath: String { ".\(rawValue)/skills" }
  }

  fileprivate struct SkillSearchRoot: Sendable {
    let scope: SkillScope
    let skillsURL: URL
    let portablePath: String
    let requiredContainerURL: URL?
  }

  struct MentionToken: Equatable, Sendable {
    let name: String
    let range: NSRange
  }

  fileprivate struct OpenAIMetadata: Decodable {
    let interface: OpenAIInterfaceFields?
  }

  fileprivate struct OpenAIInterfaceFields: Decodable {
    let displayName: String?
    let shortDescription: String?

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: OpenAIInterfaceCodingKeys.self)
      displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
      shortDescription = try container.decodeIfPresent(String.self, forKey: .shortDescription)
    }
  }

  fileprivate enum OpenAIInterfaceCodingKeys: String, CodingKey {
    case displayName = "display_name"
    case shortDescription = "short_description"
  }

  fileprivate struct Frontmatter: Decodable {
    let name: String
    let description: String
    let license: String?
    let compatibility: String?
    let metadata: [String: String]?
    let allowedTools: String?

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: FrontmatterCodingKeys.self)
      name = try container.decode(String.self, forKey: .name)
      description = try container.decode(String.self, forKey: .description)
      license = try container.decodeIfPresent(String.self, forKey: .license)
      compatibility = try container.decodeIfPresent(String.self, forKey: .compatibility)
      metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata)
      allowedTools = try container.decodeIfPresent(String.self, forKey: .allowedTools)
    }
  }

  fileprivate enum FrontmatterCodingKeys: String, CodingKey {
    case name
    case description
    case license
    case compatibility
    case metadata
    case allowedTools = "allowed-tools"
  }

  fileprivate enum ParseError: LocalizedError {
    case missingOpeningDelimiter
    case missingClosingDelimiter
    case malformedYAML(String)
    case invalidName(String)
    case directoryNameMismatch(expected: String, actual: String)
    case invalidDescription
    case invalidLicense
    case invalidCompatibility
    case invalidMetadata
    case invalidAllowedTools

    var errorDescription: String? {
      switch self {
      case .missingOpeningDelimiter:
        "SKILL.md must begin with an opening '---' frontmatter delimiter."
      case .missingClosingDelimiter:
        "SKILL.md is missing its closing '---' frontmatter delimiter."
      case .malformedYAML(let detail):
        "Could not decode YAML frontmatter: \(detail)"
      case .invalidName(let name):
        "Skill name '\(name)' must be 1-64 lowercase letters, digits, or hyphens without leading, trailing, or consecutive hyphens."
      case .directoryNameMismatch(let expected, let actual):
        "Skill name '\(actual)' must match its directory name '\(expected)'."
      case .invalidDescription:
        "Skill description must contain 1-1024 characters."
      case .invalidLicense:
        "Skill license must not be empty when present."
      case .invalidCompatibility:
        "Skill compatibility must contain 1-500 characters when present."
      case .invalidMetadata:
        "Skill metadata keys and values must not be empty."
      case .invalidAllowedTools:
        "Skill allowed-tools must not be empty when present."
      }
    }
  }

  fileprivate static func scan(workspace: Workspace, homeDirectoryURL: URL) -> CatalogStorage {
    let projectRoots = SkillDirectoryConvention.allCases.map { convention in
      SkillSearchRoot(
        scope: .project,
        skillsURL: workspace.rootURL.appending(
          path: convention.relativeSkillsPath,
          directoryHint: .isDirectory
        ),
        portablePath: convention.relativeSkillsPath,
        requiredContainerURL: workspace.rootURL
      )
    }
    let personalRoots = SkillDirectoryConvention.allCases.map { convention in
      SkillSearchRoot(
        scope: .personal,
        skillsURL: homeDirectoryURL.appending(
          path: convention.relativeSkillsPath,
          directoryHint: .isDirectory
        ),
        portablePath: "$HOME/" + convention.relativeSkillsPath,
        requiredContainerURL: nil
      )
    }
    var claimedNames = Set<String>()
    var allEntries: [SkillEntry] = []
    var diagnostics: [SkillDiagnostic] = []
    for root in projectRoots + personalRoots {
      let result = scanScope(root, ignoringNames: claimedNames)
      for entry in result.entries where claimedNames.insert(entry.descriptor.name).inserted {
        allEntries.append(entry)
      }
      diagnostics.append(contentsOf: result.diagnostics)
    }
    allEntries.sort(by: entrySort)
    let entries = Dictionary(uniqueKeysWithValues: allEntries.map { ($0.descriptor.id, $0) })
    diagnostics.sort(by: diagnosticSort)
    return CatalogStorage(
      entries: entries,
      snapshot: SkillCatalogSnapshot(
        skills: allEntries.map(\.descriptor),
        diagnostics: diagnostics
      )
    )
  }

  fileprivate static func prepare(
    _ submission: MessageSubmission,
    from storage: CatalogStorage
  ) throws -> PreparedSkillSubmission {
    let tokens = mentionTokens(in: submission.text)
    let sortedBindings = submission.skillMentions.sorted {
      if $0.range.location == $1.range.location {
        return $0.range.length < $1.range.length
      }
      return $0.range.location < $1.range.location
    }
    try validateBindings(sortedBindings, tokens: tokens, storage: storage)
    let bindingsByLocation = Dictionary(
      uniqueKeysWithValues: sortedBindings.map { ($0.range.location, $0) }
    )
    let entriesByName = Dictionary(
      uniqueKeysWithValues: storage.entries.values.map {
        ($0.descriptor.name.lowercased(), $0)
      }
    )

    var selectedEntries: [SkillEntry] = []
    var activatedSkillMentions: [ActivatedSkillMention] = []
    var selectedIDs = Set<SkillID>()
    for token in tokens {
      let entry: SkillEntry?
      if let binding = bindingsByLocation[token.range.location] {
        entry = storage.entries[binding.id]
      } else {
        entry = entriesByName[token.name.lowercased()]
      }
      guard let entry else {
        continue
      }
      activatedSkillMentions.append(
        ActivatedSkillMention(id: entry.descriptor.id, range: token.range)
      )
      if selectedIDs.insert(entry.descriptor.id).inserted {
        selectedEntries.append(entry)
      }
    }

    let totalCharacterCount = selectedEntries.reduce(0) { $0 + $1.content.count }
    guard totalCharacterCount <= maximumActivatedContentCharacters else {
      throw SkillActivationError.contentBudgetExceeded(
        maxCharacters: maximumActivatedContentCharacters,
        actualCharacters: totalCharacterCount
      )
    }
    return PreparedSkillSubmission(
      activatedSkills: selectedEntries.map { entry in
        ActivatedSkill(
          id: entry.descriptor.id,
          portablePath: entry.descriptor.portablePath,
          contentHash: entry.contentHash,
          content: entry.content,
          interfaceMetadata: entry.interfaceMetadata
        )
      },
      activatedSkillMentions: activatedSkillMentions,
      resourceRoots: selectedEntries.map { entry in
        SkillResourceRoot(id: entry.descriptor.id, rootURL: entry.rootURL)
      },
      totalCharacterCount: totalCharacterCount
    )
  }

  fileprivate static func validateBindings(
    _ bindings: [SkillMention],
    tokens: [MentionToken],
    storage: CatalogStorage
  ) throws {
    var previousUpperBound = 0
    for binding in bindings {
      guard binding.range.location >= previousUpperBound,
        binding.range.location >= 0,
        binding.range.length > 1,
        let entry = storage.entries[binding.id]
      else {
        if !storage.entries.keys.contains(binding.id) {
          throw SkillActivationError.unavailableSkill(binding.id)
        }
        throw SkillActivationError.invalidMention
      }
      guard
        tokens.contains(where: {
          $0.range == binding.range && $0.name == entry.descriptor.name
        })
      else {
        throw SkillActivationError.invalidMention
      }
      previousUpperBound = binding.range.location + binding.range.length
    }
  }

  static func mentionTokens(in text: String) -> [MentionToken] {
    let nsText = text as NSString
    var tokens: [MentionToken] = []
    var index = 0
    while index < nsText.length {
      guard nsText.character(at: index) == 36,
        index == 0 || !isSkillNameCodeUnit(nsText.character(at: index - 1))
      else {
        index += 1
        continue
      }
      var end = index + 1
      while end < nsText.length, isSkillNameCodeUnit(nsText.character(at: end)) {
        end += 1
      }
      guard end > index + 1 else {
        index += 1
        continue
      }
      let range = NSRange(location: index, length: end - index)
      tokens.append(
        MentionToken(
          name: nsText.substring(with: NSRange(location: index + 1, length: end - index - 1)),
          range: range
        )
      )
      index = end
    }
    return tokens
  }

  fileprivate static func isSkillNameCodeUnit(_ codeUnit: unichar) -> Bool {
    (codeUnit >= 48 && codeUnit <= 57)
      || (codeUnit >= 65 && codeUnit <= 90)
      || (codeUnit >= 97 && codeUnit <= 122)
      || codeUnit == 45
  }

  fileprivate static func scanScope(
    _ root: SkillSearchRoot,
    ignoringNames: Set<String>
  ) -> ScopeScanResult {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: root.skillsURL.path(percentEncoded: false)) else {
      return ScopeScanResult()
    }

    let canonicalSkillsURL = root.skillsURL.standardizedFileURL.resolvingSymlinksInPath()
    if let requiredContainerURL = root.requiredContainerURL {
      let canonicalContainerURL = requiredContainerURL.standardizedFileURL.resolvingSymlinksInPath()
      guard contains(canonicalSkillsURL, within: canonicalContainerURL) else {
        return ScopeScanResult(diagnostics: [
          diagnostic(
            scope: root.scope,
            path: root.portablePath,
            kind: .pathOutsideRoot,
            message: "Skills root resolves outside the workspace."
          )
        ])
      }
    }
    let children: [URL]
    do {
      let rootValues = try canonicalSkillsURL.resourceValues(forKeys: [.isDirectoryKey])
      guard rootValues.isDirectory == true else {
        return ScopeScanResult(diagnostics: [
          diagnostic(
            scope: root.scope,
            path: root.portablePath,
            kind: .cannotInspect,
            message: "Skills root is not a directory."
          )
        ])
      }
      children = try fileManager.contentsOfDirectory(
        at: canonicalSkillsURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      )
    } catch {
      return ScopeScanResult(diagnostics: [
        diagnostic(
          scope: root.scope,
          path: root.portablePath,
          kind: .cannotInspect,
          message: "Could not inspect skills root."
        )
      ])
    }

    var result = ScopeScanResult()
    for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      guard !ignoringNames.contains(child.lastPathComponent) else {
        continue
      }
      var isDirectory: ObjCBool = false
      guard
        fileManager.fileExists(
          atPath: child.path(percentEncoded: false),
          isDirectory: &isDirectory
        ), isDirectory.boolValue
      else { continue }
      scanSkill(
        root: root,
        directoryURL: child,
        canonicalSkillsURL: canonicalSkillsURL,
        into: &result
      )
    }
    return result
  }

  fileprivate static func scanSkill(
    root: SkillSearchRoot,
    directoryURL: URL,
    canonicalSkillsURL: URL,
    into result: inout ScopeScanResult
  ) {
    let directoryName = directoryURL.lastPathComponent
    let directoryPath = root.portablePath + "/" + directoryName
    let canonicalDirectoryURL = directoryURL.standardizedFileURL.resolvingSymlinksInPath()
    guard contains(canonicalDirectoryURL, within: canonicalSkillsURL) else {
      result.diagnostics.append(
        diagnostic(
          scope: root.scope,
          path: directoryPath,
          kind: .pathOutsideRoot,
          message: "Skill directory resolves outside its skills root."
        )
      )
      return
    }

    let sourceURL = directoryURL.appending(path: "SKILL.md", directoryHint: .notDirectory)
    guard FileManager.default.fileExists(atPath: sourceURL.path(percentEncoded: false)) else {
      result.diagnostics.append(
        diagnostic(
          scope: root.scope,
          path: directoryPath + "/SKILL.md",
          kind: .missingSkillFile,
          message: "Skill directory does not contain SKILL.md."
        )
      )
      return
    }

    let canonicalSourceURL = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
    guard contains(canonicalSourceURL, within: canonicalDirectoryURL) else {
      result.diagnostics.append(
        diagnostic(
          scope: root.scope,
          path: directoryPath + "/SKILL.md",
          kind: .pathOutsideRoot,
          message: "SKILL.md resolves outside its skill directory."
        )
      )
      return
    }

    do {
      let values = try canonicalSourceURL.resourceValues(forKeys: [.isRegularFileKey])
      guard values.isRegularFile == true else {
        result.diagnostics.append(
          diagnostic(
            scope: root.scope,
            path: directoryPath + "/SKILL.md",
            kind: .notRegularFile,
            message: "SKILL.md is not a regular file."
          )
        )
        return
      }
    } catch {
      result.diagnostics.append(
        diagnostic(
          scope: root.scope,
          path: directoryPath + "/SKILL.md",
          kind: .cannotRead,
          message: "Could not inspect SKILL.md."
        )
      )
      return
    }

    let data: Data
    do {
      data = try Data(contentsOf: canonicalSourceURL)
    } catch {
      result.diagnostics.append(
        diagnostic(
          scope: root.scope,
          path: directoryPath + "/SKILL.md",
          kind: .cannotRead,
          message: "Could not read SKILL.md."
        )
      )
      return
    }
    guard let content = String(data: data, encoding: .utf8) else {
      result.diagnostics.append(
        diagnostic(
          scope: root.scope,
          path: directoryPath + "/SKILL.md",
          kind: .invalidUTF8,
          message: "SKILL.md is not valid UTF-8."
        )
      )
      return
    }

    do {
      let frontmatter = try parseFrontmatter(content, directoryName: directoryName)
      let id = SkillID(scope: root.scope, name: frontmatter.name)
      let descriptor = SkillDescriptor(
        id: id,
        description: frontmatter.description,
        portablePath: directoryPath + "/SKILL.md"
      )
      result.entries.append(
        SkillEntry(
          descriptor: descriptor,
          rootURL: canonicalDirectoryURL,
          contentHash: sha256(data),
          content: content,
          interfaceMetadata: readInterfaceMetadata(in: canonicalDirectoryURL)
        )
      )
    } catch let error as ParseError {
      result.diagnostics.append(
        diagnostic(
          scope: root.scope,
          path: directoryPath + "/SKILL.md",
          kind: parseDiagnosticKind(for: error),
          message: error.localizedDescription
        )
      )
    } catch {
      result.diagnostics.append(
        diagnostic(
          scope: root.scope,
          path: directoryPath + "/SKILL.md",
          kind: .invalidFrontmatter,
          message: "Could not decode YAML frontmatter."
        )
      )
    }
  }

  fileprivate static func parseFrontmatter(_ content: String, directoryName: String) throws
    -> Frontmatter
  {
    let normalized =
      content
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
    guard lines.first == "---" else {
      throw ParseError.missingOpeningDelimiter
    }
    guard let closingIndex = lines.dropFirst().firstIndex(where: { $0 == "---" }) else {
      throw ParseError.missingClosingDelimiter
    }
    let yaml = lines[1..<closingIndex].joined(separator: "\n")
    let frontmatter: Frontmatter
    do {
      frontmatter = try YAMLDecoder().decode(Frontmatter.self, from: yaml)
    } catch {
      throw ParseError.malformedYAML(String(describing: error))
    }
    try validate(frontmatter, directoryName: directoryName)
    return frontmatter
  }

  static func persistedDescription(in skill: ActivatedSkill) -> String? {
    try? parseFrontmatter(skill.content, directoryName: skill.id.name).description
  }

  package static func persistedMarkdownBody(in skill: ActivatedSkill) -> String? {
    guard (try? parseFrontmatter(skill.content, directoryName: skill.id.name)) != nil else {
      return nil
    }
    let normalized =
      skill.content
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
    guard let closingIndex = lines.dropFirst().firstIndex(where: { $0 == "---" }) else {
      return nil
    }
    return lines[lines.index(after: closingIndex)...].joined(separator: "\n")
  }

  fileprivate static func readInterfaceMetadata(
    in canonicalSkillDirectoryURL: URL
  ) -> SkillInterfaceMetadata? {
    let metadataURL =
      canonicalSkillDirectoryURL
      .appending(path: "agents", directoryHint: .isDirectory)
      .appending(path: "openai.yaml", directoryHint: .notDirectory)
    guard FileManager.default.fileExists(atPath: metadataURL.path(percentEncoded: false)) else {
      return nil
    }
    let canonicalMetadataURL = metadataURL.standardizedFileURL.resolvingSymlinksInPath()
    guard contains(canonicalMetadataURL, within: canonicalSkillDirectoryURL) else {
      return nil
    }
    guard
      let values = try? canonicalMetadataURL.resourceValues(forKeys: [.isRegularFileKey]),
      values.isRegularFile == true,
      let data = try? Data(contentsOf: canonicalMetadataURL),
      let content = String(data: data, encoding: .utf8),
      let metadata = try? YAMLDecoder().decode(OpenAIMetadata.self, from: content)
    else {
      return nil
    }
    return SkillInterfaceMetadata.make(
      displayName: metadata.interface?.displayName,
      shortDescription: metadata.interface?.shortDescription
    )
  }

  fileprivate static func validate(_ frontmatter: Frontmatter, directoryName: String) throws {
    let name = frontmatter.name
    let allowedNameCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
    guard (1...64).contains(name.count),
      name.unicodeScalars.allSatisfy(allowedNameCharacters.contains),
      !name.hasPrefix("-"),
      !name.hasSuffix("-"),
      !name.contains("--")
    else {
      throw ParseError.invalidName(name)
    }
    guard name == directoryName else {
      throw ParseError.directoryNameMismatch(expected: directoryName, actual: name)
    }

    let description = frontmatter.description.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (1...1024).contains(description.count) else {
      throw ParseError.invalidDescription
    }
    if let license = frontmatter.license,
      license.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      throw ParseError.invalidLicense
    }
    if let compatibility = frontmatter.compatibility {
      let trimmed = compatibility.trimmingCharacters(in: .whitespacesAndNewlines)
      guard (1...500).contains(trimmed.count) else {
        throw ParseError.invalidCompatibility
      }
    }
    if let metadata = frontmatter.metadata,
      metadata.contains(where: {
        $0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          || $0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      })
    {
      throw ParseError.invalidMetadata
    }
    if let allowedTools = frontmatter.allowedTools,
      allowedTools.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      throw ParseError.invalidAllowedTools
    }
  }

  fileprivate static func contains(_ candidateURL: URL, within rootURL: URL) -> Bool {
    let rootPath = normalizedPath(rootURL)
    let candidatePath = normalizedPath(candidateURL)
    return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
  }

  fileprivate static func normalizedPath(_ url: URL) -> String {
    var path = url.standardizedFileURL.path(percentEncoded: false)
    while path.count > 1, path.hasSuffix("/") {
      path.removeLast()
    }
    return path
  }

  fileprivate static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  fileprivate static func diagnostic(
    scope: SkillScope,
    path: String,
    kind: SkillDiagnosticKind,
    message: String
  ) -> SkillDiagnostic {
    SkillDiagnostic(scope: scope, portablePath: path, kind: kind, message: message)
  }

  fileprivate static func parseDiagnosticKind(for error: ParseError) -> SkillDiagnosticKind {
    switch error {
    case .missingOpeningDelimiter, .missingClosingDelimiter, .malformedYAML:
      .invalidFrontmatter
    case .invalidName, .directoryNameMismatch, .invalidDescription, .invalidLicense,
      .invalidCompatibility, .invalidMetadata, .invalidAllowedTools:
      .invalidMetadata
    }
  }

  fileprivate static func entrySort(_ lhs: SkillEntry, _ rhs: SkillEntry) -> Bool {
    if lhs.descriptor.scope.sortOrder != rhs.descriptor.scope.sortOrder {
      return lhs.descriptor.scope.sortOrder < rhs.descriptor.scope.sortOrder
    }
    return lhs.descriptor.name.localizedCaseInsensitiveCompare(rhs.descriptor.name)
      == .orderedAscending
  }

  fileprivate static func diagnosticSort(_ lhs: SkillDiagnostic, _ rhs: SkillDiagnostic) -> Bool {
    if lhs.scope.sortOrder != rhs.scope.sortOrder {
      return lhs.scope.sortOrder < rhs.scope.sortOrder
    }
    return lhs.portablePath.localizedCaseInsensitiveCompare(rhs.portablePath) == .orderedAscending
  }
}
