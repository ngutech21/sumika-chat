import Foundation

public struct ModelContextDebugDocument: Equatable, Sendable {
  public let systemPrompt: ModelContextDebugEntry
  public let entries: [ModelContextDebugEntry]
  public let totalCharacters: Int
  public let totalEstimatedTokens: Int
  public let signature: String
  public let renderedContext: String
}

public struct ModelContextDebugEntry: Identifiable, Equatable, Sendable {
  public let id: String
  public let index: Int?
  public let role: ModelContextDebugRole
  public let content: String
  public let characterCount: Int
  public let estimatedTokens: Int

  public init(
    id: String? = nil,
    index: Int?,
    role: ModelContextDebugRole,
    content: String
  ) {
    self.index = index
    self.role = role
    self.content = content
    self.id = id ?? Self.stableID(index: index, role: role)
    characterCount = content.count
    estimatedTokens = Self.estimatedTokens(for: content)
  }

  private static func stableID(index: Int?, role: ModelContextDebugRole) -> String {
    guard let index else {
      return role.rawValue
    }
    return "\(index)-\(role.rawValue)"
  }

  private static func estimatedTokens(for content: String) -> Int {
    guard !content.isEmpty else {
      return 0
    }
    return Int(ceil(Double(content.count) / 4.0))
  }
}

public enum ModelContextDebugRole: String, Equatable, Sendable {
  case system
  case user
  case assistant
  case tool
}

public enum ModelContextDebugRenderer {
  public static func render(
    transcript: ModelPromptProjection,
    systemPrompt: String,
    projectionMode: ModelContextProjectionMode = .fullHistory
  ) throws -> ModelContextDebugDocument {
    let normalizedSystemPrompt =
      ModelFacingPromptRenderer.normalizedSystemPrompt(systemPrompt) ?? ""
    let systemEntry = ModelContextDebugEntry(
      index: nil,
      role: .system,
      content: normalizedSystemPrompt
    )
    let projectedEntries = transcript.projectedEntries(mode: projectionMode)
    let entries =
      projectedEntries
      .enumerated()
      .map { offset, entry in
        ModelContextDebugEntry(
          index: offset + 1,
          role: ModelContextDebugRole(entry.role),
          content: entry.content
        )
      }
    let totalCharacters =
      systemEntry.characterCount
      + entries.reduce(0) {
        $0 + $1.characterCount
      }
    let totalEstimatedTokens =
      systemEntry.estimatedTokens
      + entries.reduce(0) {
        $0 + $1.estimatedTokens
      }
    let renderedContext = renderContext(systemPrompt: systemEntry, entries: entries)
    let signature = signature(
      systemPrompt: systemEntry.content,
      projectionMode: projectionMode,
      entries: entries
    )

    return ModelContextDebugDocument(
      systemPrompt: systemEntry,
      entries: entries,
      totalCharacters: totalCharacters,
      totalEstimatedTokens: totalEstimatedTokens,
      signature: signature,
      renderedContext: renderedContext
    )
  }

  private static func renderContext(
    systemPrompt: ModelContextDebugEntry,
    entries: [ModelContextDebugEntry]
  ) -> String {
    ([systemPrompt] + entries)
      .map { entry in
        let title =
          if let index = entry.index {
            "\(index). \(entry.role.rawValue)"
          } else {
            entry.role.rawValue
          }
        return """
          === \(title) ===
          \(entry.content)
          """
      }
      .joined(separator: "\n\n")
  }

  private static func signature(
    systemPrompt: String,
    projectionMode: ModelContextProjectionMode,
    entries: [ModelContextDebugEntry]
  ) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    func update(_ byte: UInt8) {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    func update(_ value: String) {
      for byte in value.utf8 {
        update(byte)
      }
      update(0)
    }

    update("model-context-debug-v1")
    update(projectionMode.signatureComponent)
    update("system")
    update(systemPrompt)
    for entry in entries {
      update(entry.role.rawValue)
      update(entry.content)
    }
    return String(format: "%016llx", hash)
  }
}

extension ModelContextDebugRole {
  fileprivate init(_ role: ModelContextRole) {
    switch role {
    case .user:
      self = .user
    case .assistant:
      self = .assistant
    case .tool:
      self = .tool
    }
  }
}
