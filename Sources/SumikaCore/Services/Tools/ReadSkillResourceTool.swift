import Foundation

private enum ReadSkillResourceLimits {
  static let maximumLinesPerPage = 500
  static let renderedContentBytesPerPage = 16 * 1024
}

package struct ReadSkillResourceInput: Codable, Equatable, Sendable {
  package let skillID: SkillID
  package let path: String
  package let offset: Int?
  package let limit: Int?

  private enum CodingKeys: String, CodingKey {
    case skillID = "skill_id"
    case path
    case offset
    case limit
  }

  package init(
    skillID: SkillID,
    path: String,
    offset: Int? = nil,
    limit: Int? = nil
  ) {
    self.skillID = skillID
    self.path = path
    self.offset = offset
    self.limit = limit
  }

  package init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    skillID = try container.decode(SkillID.self, forKey: .skillID)
    path = try container.decode(String.self, forKey: .path)
    offset = try Self.decodeOptionalInt(from: container, forKey: .offset)
    limit = try Self.decodeOptionalInt(from: container, forKey: .limit)
    guard offset.map({ $0 >= 1 }) ?? true else {
      throw InvalidToolCallReason.invalidPagination("offset")
    }
    guard limit.map({ $0 >= 1 }) ?? true else {
      throw InvalidToolCallReason.invalidPagination("limit")
    }
  }

  private static func decodeOptionalInt(
    from container: KeyedDecodingContainer<CodingKeys>,
    forKey key: CodingKeys
  ) throws -> Int? {
    guard container.contains(key) else { return nil }
    if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
      return value
    }
    if let string = try? container.decodeIfPresent(String.self, forKey: key),
      let value = Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
    {
      return value
    }
    throw InvalidToolCallReason.invalidPagination(key.stringValue)
  }
}

package struct ReadSkillResourcePage: Codable, Equatable, Sendable {
  package let skillID: SkillID
  package let path: String
  package let startLine: Int
  package let endLine: Int?
  package let content: String
  package let continuation: ReadFileContinuation

  package var numberedContent: String {
    guard let endLine else { return "" }
    return zip(startLine...endLine, content.components(separatedBy: "\n"))
      .map { lineNumber, line in
        "\(ReadFilePage.lineNumberPrefix(for: lineNumber))\(line)"
      }
      .joined(separator: "\n")
  }

  package var textOutput: ToolTextOutput {
    ToolTextOutput(text: numberedContent, truncated: continuation != .endOfFile)
  }

  package var affectedPath: WorkspaceRelativePath {
    WorkspaceRelativePath(rawValue: "\(skillID.rawValue)/\(path)")
  }
}

package enum ReadSkillResourceResult: Codable, Equatable, Sendable {
  case page(ReadSkillResourcePage)
  case failed(skillID: SkillID, path: String, message: String, status: ToolResultStatus)

  private enum CodingKeys: String, CodingKey {
    case kind
    case page
    case skillID = "skill_id"
    case path
    case message
    case status
  }

  private enum Kind: String, Codable {
    case page
    case failed
  }

  package init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .page:
      self = .page(try container.decode(ReadSkillResourcePage.self, forKey: .page))
    case .failed:
      self = .failed(
        skillID: try container.decode(SkillID.self, forKey: .skillID),
        path: try container.decode(String.self, forKey: .path),
        message: try container.decode(String.self, forKey: .message),
        status: try container.decode(ToolResultStatus.self, forKey: .status)
      )
    }
  }

  package func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .page(let page):
      try container.encode(Kind.page, forKey: .kind)
      try container.encode(page, forKey: .page)
    case .failed(let skillID, let path, let message, let status):
      try container.encode(Kind.failed, forKey: .kind)
      try container.encode(skillID, forKey: .skillID)
      try container.encode(path, forKey: .path)
      try container.encode(message, forKey: .message)
      try container.encode(status, forKey: .status)
    }
  }
}

nonisolated extension ReadSkillResourceResult {
  package var preview: ToolResultPreview {
    switch self {
    case .page(let page):
      ToolResultPreview(
        text: page.textOutput.text,
        truncated: page.textOutput.truncated,
        affectedPaths: [page.affectedPath.rawValue]
      )
    case .failed(let skillID, let path, let message, let status):
      ToolResultPreview(
        status: status,
        text: message,
        affectedPaths: ["\(skillID.rawValue)/\(path)"]
      )
    }
  }
}

nonisolated extension ToolDefinition {
  package static let readSkillResource = ToolDefinition(
    name: .readSkillResource,
    description:
      "Read a UTF-8 resource from a skill explicitly activated for the current user message. This does not execute or modify the resource.",
    parameters: [
      ToolParameterDefinition(
        name: "skill_id",
        description: "Activated skill ID, including scope (for example project:code-review).",
        isRequired: true
      ),
      ToolParameterDefinition(
        name: "path",
        description: "Path relative to that skill directory.",
        isRequired: true
      ),
      ToolParameterDefinition(
        name: "offset",
        description: "1-based start line.",
        isRequired: false,
        valueType: .integer,
        minimum: 1
      ),
      ToolParameterDefinition(
        name: "limit",
        description: "Maximum lines to return, capped at 500.",
        isRequired: false,
        valueType: .integer,
        defaultValue: .number(Double(ReadSkillResourceLimits.maximumLinesPerPage)),
        minimum: 1,
        maximum: Double(ReadSkillResourceLimits.maximumLinesPerPage)
      ),
    ],
    capabilities: [.readWorkspace],
    riskLevel: .low
  )
}

struct ReadSkillResourceToolExecutor: TypedToolExecutor {
  static let codec = ToolCodec<ReadSkillResourceInput>(
    definition: ToolDefinition.readSkillResource,
    makePayload: ToolCallPayload.readSkillResource,
    extractInput: { payload in
      guard case .readSkillResource(let input) = payload else {
        throw ToolInputDecodingError.payloadMismatch(
          expected: ToolDefinition.readSkillResource.name.rawValue,
          actual: payload.toolName.rawValue
        )
      }
      return input
    },
    validateInput: { input in
      try ToolArgumentValidation.requireNonEmptyString(
        input.skillID.rawValue,
        name: "skill_id",
        expected: "a scoped skill ID"
      )
      try ToolArgumentValidation.requireNonEmptyPath(input.path)
    }
  )

  private let rootsByID: [SkillID: URL]

  init(resourceRoots: [SkillResourceRoot]) {
    rootsByID = Dictionary(
      uniqueKeysWithValues: resourceRoots.map { root in
        (root.id, root.rootURL.standardizedFileURL)
      }
    )
  }

  func evaluatePermission(
    _ input: ReadSkillResourceInput,
    context: ToolContext
  ) -> ToolPermissionEvaluation {
    do {
      _ = try context.workspace.withSecurityScopedAccess {
        try resolve(input)
      }
      return ToolPermissionEvaluation(
        decision: .allowed,
        reason: "Reading a resource inside an activated skill is allowed.",
        riskLevel: .low,
        workspaceRelativePaths: [portablePath(for: input)]
      )
    } catch let error as ResolutionError {
      return ToolPermissionEvaluation(
        decision: .denied,
        reason: error.localizedDescription,
        riskLevel: .low,
        workspaceRelativePaths: [portablePath(for: input)]
      )
    } catch {
      return ToolPermissionEvaluation(
        decision: .denied,
        reason: error.localizedDescription,
        riskLevel: .low
      )
    }
  }

  func run(
    _ input: ReadSkillResourceInput,
    context: ToolContext
  ) async -> ToolResultPayload {
    do {
      return try context.workspace.withSecurityScopedAccess {
        let url = try resolve(input)
        guard
          let result = try ReadFileToolExecutor.readPage(
            from: url,
            path: portablePath(for: input),
            startLine: input.offset ?? 1,
            maxLines: min(
              input.limit ?? ReadSkillResourceLimits.maximumLinesPerPage,
              ReadSkillResourceLimits.maximumLinesPerPage
            ),
            maxBytes: ReadSkillResourceLimits.renderedContentBytesPerPage
          )
        else {
          return failed(input, message: "Skill resource is not valid UTF-8.", status: .failed)
        }
        return mapReadResult(result, input: input)
      }
    } catch let error as ResolutionError {
      return failed(input, message: error.localizedDescription, status: error.resultStatus)
    } catch {
      return failed(input, message: error.localizedDescription, status: .failed)
    }
  }

  private func mapReadResult(
    _ result: ReadFileResult,
    input: ReadSkillResourceInput
  ) -> ToolResultPayload {
    switch result {
    case .page(let page):
      return .readSkillResource(
        .page(
          ReadSkillResourcePage(
            skillID: input.skillID,
            path: input.path,
            startLine: page.startLine,
            endLine: page.endLine,
            content: page.content,
            continuation: page.continuation
          )
        )
      )
    case .lineTooLong(_, let line, let byteCount):
      return failed(
        input,
        message:
          "Line \(line) is \(byteCount) bytes and cannot fit in one skill resource page.",
        status: .failed
      )
    case .offsetOutOfRange(_, let requestedOffset, let lineCount):
      return failed(
        input,
        message:
          "Skill resource offset \(requestedOffset) is past the end of the file, which has \(lineCount) lines.",
        status: .failed
      )
    case .legacySuccess, .unchanged, .repeatedReadWarning, .failed:
      return failed(input, message: "Skill resource read failed.", status: .failed)
    }
  }

  private func resolve(_ input: ReadSkillResourceInput) throws -> URL {
    guard let configuredRootURL = rootsByID[input.skillID] else {
      throw ResolutionError.inactiveSkill(input.skillID)
    }
    let rootURL = configuredRootURL.resolvingSymlinksInPath()
    let path = input.path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty else {
      throw ResolutionError.emptyPath
    }
    guard !path.hasPrefix("/"), URL(string: path)?.scheme == nil else {
      throw ResolutionError.absolutePath
    }
    guard !NSString(string: path).pathComponents.contains("..") else {
      throw ResolutionError.pathOutsideSkill
    }
    let candidateURL = rootURL.appending(path: path).standardizedFileURL
      .resolvingSymlinksInPath()
    guard Self.contains(candidateURL, within: rootURL) else {
      throw ResolutionError.pathOutsideSkill
    }
    let values = try candidateURL.resourceValues(forKeys: [.isRegularFileKey])
    guard values.isRegularFile == true else {
      throw ResolutionError.notRegularFile
    }
    return candidateURL
  }

  private func failed(
    _ input: ReadSkillResourceInput,
    message: String,
    status: ToolResultStatus
  ) -> ToolResultPayload {
    .readSkillResource(
      .failed(skillID: input.skillID, path: input.path, message: message, status: status)
    )
  }

  private func portablePath(for input: ReadSkillResourceInput) -> WorkspaceRelativePath {
    WorkspaceRelativePath(rawValue: "\(input.skillID.rawValue)/\(input.path)")
  }

  private static func contains(_ candidateURL: URL, within rootURL: URL) -> Bool {
    let rootPath = normalizedPath(rootURL)
    let candidatePath = normalizedPath(candidateURL)
    return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
  }

  private static func normalizedPath(_ url: URL) -> String {
    var path = url.standardizedFileURL.path(percentEncoded: false)
    while path.count > 1, path.hasSuffix("/") {
      path.removeLast()
    }
    return path
  }

  private enum ResolutionError: LocalizedError {
    case inactiveSkill(SkillID)
    case emptyPath
    case absolutePath
    case pathOutsideSkill
    case notRegularFile

    var errorDescription: String? {
      switch self {
      case .inactiveSkill(let id):
        "Skill '\(id.rawValue)' is not activated for this turn."
      case .emptyPath:
        "Skill resource path is empty."
      case .absolutePath:
        "Skill resource path must be relative."
      case .pathOutsideSkill:
        "Skill resource path resolves outside the activated skill."
      case .notRegularFile:
        "Skill resource is not a regular file."
      }
    }

    var resultStatus: ToolResultStatus {
      switch self {
      case .inactiveSkill, .emptyPath, .absolutePath, .pathOutsideSkill, .notRegularFile:
        .denied
      }
    }
  }
}
