// Crypto is used directly here; the analyzer compiler log does not attribute it reliably.
// swiftlint:disable:next unused_import
import Crypto
import Foundation

package enum SkillScope: String, Codable, CaseIterable, Sendable {
  case project
  case personal

  var sortOrder: Int {
    switch self {
    case .project: 0
    case .personal: 1
    }
  }
}

package struct SkillID: RawRepresentable, Codable, Hashable, Identifiable, Sendable {
  package let scope: SkillScope
  package let name: String

  package var rawValue: String {
    "\(scope.rawValue):\(name)"
  }

  package var id: String { rawValue }

  package init(scope: SkillScope, name: String) {
    self.scope = scope
    self.name = name
  }

  package init?(rawValue: String) {
    let components = rawValue.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    guard components.count == 2,
      let scope = SkillScope(rawValue: String(components[0])),
      !components[1].isEmpty
    else {
      return nil
    }
    self.init(scope: scope, name: String(components[1]))
  }

  package init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let rawValue = try container.decode(String.self)
    guard let id = Self(rawValue: rawValue) else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Invalid skill ID: \(rawValue)"
      )
    }
    self = id
  }

  package func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

package struct SkillDescriptor: Equatable, Identifiable, Sendable {
  package let id: SkillID
  package let description: String
  package let portablePath: String

  package var name: String { id.name }
  package var scope: SkillScope { id.scope }

  package init(id: SkillID, description: String, portablePath: String) {
    self.id = id
    self.description = description
    self.portablePath = portablePath
  }
}

package enum SkillDiagnosticKind: String, Codable, Sendable {
  case cannotInspect
  case missingSkillFile
  case pathOutsideRoot
  case notRegularFile
  case cannotRead
  case invalidUTF8
  case invalidFrontmatter
  case invalidMetadata
}

package struct SkillDiagnostic: Equatable, Identifiable, Sendable {
  package let scope: SkillScope
  package let portablePath: String
  package let kind: SkillDiagnosticKind
  package let message: String

  package var id: String {
    "\(scope.rawValue):\(portablePath):\(kind.rawValue):\(message)"
  }

  package init(
    scope: SkillScope,
    portablePath: String,
    kind: SkillDiagnosticKind,
    message: String
  ) {
    self.scope = scope
    self.portablePath = portablePath
    self.kind = kind
    self.message = message
  }
}

package struct SkillCatalogSnapshot: Equatable, Sendable {
  package let skills: [SkillDescriptor]
  package let diagnostics: [SkillDiagnostic]

  package init(skills: [SkillDescriptor], diagnostics: [SkillDiagnostic]) {
    self.skills = skills
    self.diagnostics = diagnostics
  }

  package static let empty = SkillCatalogSnapshot(skills: [], diagnostics: [])
}

package struct SkillMention: Equatable, Sendable {
  package let id: SkillID
  package let range: NSRange

  package init(id: SkillID, range: NSRange) {
    self.id = id
    self.range = range
  }
}

package struct SkillInterfaceMetadata: Codable, Equatable, Sendable {
  package let displayName: String?
  package let shortDescription: String?

  package init(displayName: String? = nil, shortDescription: String? = nil) {
    self.displayName = Self.nonEmpty(displayName)
    self.shortDescription = Self.nonEmpty(shortDescription)
  }

  private enum CodingKeys: String, CodingKey {
    case displayName
    case shortDescription
  }

  package init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      displayName: try container.decodeIfPresent(String.self, forKey: .displayName),
      shortDescription: try container.decodeIfPresent(String.self, forKey: .shortDescription)
    )
  }

  package func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(displayName, forKey: .displayName)
    try container.encodeIfPresent(shortDescription, forKey: .shortDescription)
  }

  static func make(
    displayName: String?,
    shortDescription: String?
  ) -> SkillInterfaceMetadata? {
    let metadata = SkillInterfaceMetadata(
      displayName: displayName,
      shortDescription: shortDescription
    )
    guard metadata.displayName != nil || metadata.shortDescription != nil else {
      return nil
    }
    return metadata
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value else {
      return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

package struct ActivatedSkillMention: Codable, Equatable, Sendable {
  package let id: SkillID
  package let range: NSRange

  package init(id: SkillID, range: NSRange) {
    self.id = id
    self.range = range
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case location
    case length
  }

  package init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(SkillID.self, forKey: .id)
    range = NSRange(
      location: try container.decode(Int.self, forKey: .location),
      length: try container.decode(Int.self, forKey: .length)
    )
  }

  package func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(range.location, forKey: .location)
    try container.encode(range.length, forKey: .length)
  }
}

package struct MessageSubmission: Equatable, Sendable {
  package let text: String
  package let skillMentions: [SkillMention]

  package init(text: String, skillMentions: [SkillMention] = []) {
    self.text = text
    self.skillMentions = skillMentions
  }
}

package struct ActivatedSkill: Codable, Equatable, Sendable {
  package let id: SkillID
  package let portablePath: String
  package let contentHash: String
  package let content: String
  package let interfaceMetadata: SkillInterfaceMetadata?

  package init(
    id: SkillID,
    portablePath: String,
    contentHash: String,
    content: String,
    interfaceMetadata: SkillInterfaceMetadata? = nil
  ) {
    precondition(Self.isPortablePath(portablePath), "Activated skill path must be portable.")
    precondition(contentHash == Self.sha256(content), "Activated skill hash must match content.")
    self.id = id
    self.portablePath = portablePath
    self.contentHash = contentHash
    self.content = content
    self.interfaceMetadata = interfaceMetadata
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case portablePath
    case contentHash
    case content
    case interfaceMetadata
  }

  package init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let id = try container.decode(SkillID.self, forKey: .id)
    let portablePath = try container.decode(String.self, forKey: .portablePath)
    let contentHash = try container.decode(String.self, forKey: .contentHash)
    let content = try container.decode(String.self, forKey: .content)
    let interfaceMetadata = try? container.decodeIfPresent(
      SkillInterfaceMetadata.self,
      forKey: .interfaceMetadata
    )
    guard Self.isPortablePath(portablePath),
      contentHash == Self.sha256(content)
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .contentHash,
        in: container,
        debugDescription: "Activated skill path, content, and hash must agree."
      )
    }
    self.init(
      id: id,
      portablePath: portablePath,
      contentHash: contentHash,
      content: content,
      interfaceMetadata: interfaceMetadata
    )
  }

  private static func isPortablePath(_ path: String) -> Bool {
    !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
  }

  private static func sha256(_ content: String) -> String {
    SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}

package struct SkillResourceRoot: Equatable, Sendable {
  package let id: SkillID
  package let rootURL: URL

  package init(id: SkillID, rootURL: URL) {
    self.id = id
    self.rootURL = rootURL
  }
}

package struct PreparedSkillSubmission: Equatable, Sendable {
  package let activatedSkills: [ActivatedSkill]
  package let activatedSkillMentions: [ActivatedSkillMention]
  package let resourceRoots: [SkillResourceRoot]
  package let totalCharacterCount: Int

  package init(
    activatedSkills: [ActivatedSkill],
    activatedSkillMentions: [ActivatedSkillMention],
    resourceRoots: [SkillResourceRoot],
    totalCharacterCount: Int
  ) {
    self.activatedSkills = activatedSkills
    self.activatedSkillMentions = activatedSkillMentions
    self.resourceRoots = resourceRoots
    self.totalCharacterCount = totalCharacterCount
  }

  package static let empty = PreparedSkillSubmission(
    activatedSkills: [],
    activatedSkillMentions: [],
    resourceRoots: [],
    totalCharacterCount: 0
  )
}

package enum SkillActivationError: LocalizedError, Equatable, Sendable {
  case invalidMention
  case unavailableSkill(SkillID)
  case contentBudgetExceeded(maxCharacters: Int, actualCharacters: Int)

  package var errorDescription: String? {
    switch self {
    case .invalidMention:
      "A selected skill mention no longer matches the message. Select the skill again."
    case .unavailableSkill(let id):
      "The selected skill '\(id.rawValue)' is no longer available."
    case .contentBudgetExceeded(let maxCharacters, let actualCharacters):
      "Activated skills contain \(actualCharacters) characters; the limit is \(maxCharacters)."
    }
  }
}

package struct ActivatedSkillMentionPresentation: Equatable, Sendable {
  package let range: NSRange
  package let displayName: String
  package let tooltip: String
}

extension UserTurnMessage {
  package var activatedSkillMentionPresentations: [ActivatedSkillMentionPresentation] {
    let skillsByID = Dictionary(
      promptContext.activatedSkills.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let mentions: [ActivatedSkillMention]
    if activatedSkillMentions.isEmpty {
      let skillsByName = Dictionary(grouping: promptContext.activatedSkills) {
        $0.id.name.lowercased()
      }
      mentions = SkillCatalog.mentionTokens(in: content).compactMap { token in
        let matchingSkills = skillsByName[token.name.lowercased()] ?? []
        guard matchingSkills.count == 1, let skill = matchingSkills.first else {
          return nil
        }
        return ActivatedSkillMention(id: skill.id, range: token.range)
      }
    } else {
      mentions = activatedSkillMentions
    }

    return mentions.compactMap { mention in
      guard let skill = skillsByID[mention.id],
        let tooltip = skill.interfaceMetadata?.shortDescription
          ?? SkillCatalog.persistedDescription(in: skill)
      else {
        return nil
      }
      return ActivatedSkillMentionPresentation(
        range: mention.range,
        displayName: skill.interfaceMetadata?.displayName ?? "$\(skill.id.name)",
        tooltip: tooltip
      )
    }
  }
}
