import Foundation

package struct ReadDocumentInput: Codable, Equatable, Sendable {
  package let path: String

  func resolve(in workspace: Workspace) throws -> URL {
    let input = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !input.hasPrefix("/"), URL(string: input)?.scheme == nil else {
      throw ReadDocumentFailure.relativePathRequired
    }
    return try workspace.resolveAllowedPath(input)
  }
}

package struct ReadDocumentContent: Codable, Equatable, Sendable {
  package let path: WorkspaceRelativePath
  package let markdown: String

  init(path: WorkspaceRelativePath, markdown: String) throws {
    guard markdown.utf8.count <= DocumentContentPolicy.maximumMarkdownBytes else {
      throw ReadDocumentFailure.markdownTooLarge
    }
    guard markdown.count <= DocumentContentPolicy.maximumContentCharacters else {
      throw ReadDocumentFailure.contentTooLarge
    }
    guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ReadDocumentFailure.emptyContent
    }
    self.path = path
    self.markdown = markdown
  }

  private enum CodingKeys: String, CodingKey {
    case path, markdown
  }

  package init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      path: container.decode(WorkspaceRelativePath.self, forKey: .path),
      markdown: container.decode(String.self, forKey: .markdown)
    )
  }
}

package enum ReadDocumentFailure: Error, Codable, Equatable, Sendable {
  case relativePathRequired
  case unsupportedFormat
  case notRegularFile
  case sourceSizeUnavailable
  case sourceTooLarge
  case markdownTooLarge
  case contentTooLarge
  case emptyContent
  case needsOCR
  case conversionFailed
  case unreadableFile
  case file(ToolFailureReason)

  var status: ToolResultStatus {
    switch self {
    case .relativePathRequired: .denied
    case .file(let reason): reason.previewStatus
    default: .failed
    }
  }

  var message: String {
    let detail: String =
      switch self {
      case .relativePathRequired:
        "Use a relative path inside the active workspace, not an absolute path or URL."
      case .unsupportedFormat:
        "This document format is unsupported. Use read_file for ordinary UTF-8 text."
      case .notRegularFile:
        "The path must identify a regular document file."
      case .sourceSizeUnavailable:
        "The document size could not be determined."
      case .sourceTooLarge:
        "The document exceeds the 64 MiB source limit. Use a smaller document."
      case .markdownTooLarge:
        "The converted Markdown exceeds the 256 KiB limit. Use a smaller document."
      case .contentTooLarge:
        "The document exceeds the 32,000 extracted-character limit. Use a smaller document."
      case .emptyContent:
        "The document contains no readable text."
      case .needsOCR:
        "The document requires OCR, which read_document does not support. Provide a text-based document."
      case .conversionFailed:
        "The document could not be converted. Provide a supported, readable document."
      case .unreadableFile:
        "The document could not be read. Check that the file is accessible and try again."
      case .file(let reason): reason.message
      }
    return
      "\(detail) No document content was returned. Do not infer content from its filename or metadata."
  }
}

package enum ReadDocumentResult: Codable, Equatable, Sendable {
  case success(ReadDocumentContent)
  case failed(path: WorkspaceRelativePath?, reason: ReadDocumentFailure)

  var preview: ToolResultPreview {
    switch self {
    case .success(let content):
      ToolResultPreview(
        text: "Read document \(content.path.rawValue).",
        affectedPaths: [content.path.rawValue]
      )
    case .failed(let path, let reason):
      ToolResultPreview(
        status: reason.status,
        text: reason.message,
        affectedPaths: path.map { [$0.rawValue] } ?? []
      )
    }
  }
}

nonisolated extension ToolDefinition {
  static let readDocument = ToolDefinition(
    name: .readDocument,
    description:
      "Read a supported workspace document (PDF, Office, EPUB or RTF) as complete converted Markdown for analysis. Limited to 32,000 extracted characters; no OCR or partial results. Derived text cannot be used to edit the original document. Chat attachments already supply their content; do not pass attachment names here.",
    parameters: [
      ToolParameterDefinition(
        name: "path", description: "Workspace-relative document path.", isRequired: true
      )
    ],
    capabilities: [.readWorkspace],
    riskLevel: .low
  )
}

struct ReadDocumentToolExecutor: TypedToolExecutor {
  static let codec = ToolCodec<ReadDocumentInput>(
    definition: .readDocument,
    makePayload: ToolCallPayload.readDocument,
    extractInput: { payload in
      guard case .readDocument(let input) = payload else {
        throw ToolInputDecodingError.payloadMismatch(
          expected: ToolName.readDocument.rawValue, actual: payload.toolName.rawValue
        )
      }
      return input
    },
    validateInput: { try ToolArgumentValidation.requireNonEmptyPath($0.path) }
  )

  private let converter: any DocumentMarkdownConverting
  private let sourceSize: @Sendable (URL) throws -> Int?

  init(
    converter: any DocumentMarkdownConverting,
    sourceSize: @escaping @Sendable (URL) throws -> Int? = {
      try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize
    }
  ) {
    self.converter = converter
    self.sourceSize = sourceSize
  }

  func evaluatePermission(
    _ input: ReadDocumentInput, context: ToolContext
  ) -> ToolPermissionEvaluation {
    do {
      let url = try input.resolve(in: context.workspace)
      return ToolPermissionEvaluation(
        decision: .allowed, reason: "Reading documents inside the workspace is allowed.",
        riskLevel: .low, normalizedPaths: [url.path(percentEncoded: false)],
        workspaceRelativePaths: [context.workspace.relativePath(for: url)]
      )
    } catch {
      return ToolPermissionEvaluation(
        decision: .denied, reason: failure(for: error).message, riskLevel: .low
      )
    }
  }

  func run(_ input: ReadDocumentInput, context: ToolContext) async -> ToolResultPayload {
    var path: WorkspaceRelativePath?
    do {
      let workspace = context.workspace
      let readTask = Task.detached(priority: .userInitiated) {
        try workspace.withSecurityScopedAccess {
          try Task.checkCancellation()
          let url = try input.resolve(in: workspace)
          let path = workspace.relativePath(for: url)
          guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw ReadDocumentFailure.notRegularFile
          }
          guard
            DocumentContentPolicy.supportedFileExtensions.contains(url.pathExtension.lowercased())
          else { throw ReadDocumentFailure.unsupportedFormat }
          guard let size = try sourceSize(url), size >= 0 else {
            throw ReadDocumentFailure.sourceSizeUnavailable
          }
          guard size <= DocumentContentPolicy.maximumSourceBytes else {
            throw ReadDocumentFailure.sourceTooLarge
          }
          let handle = try FileHandle(forReadingFrom: url)
          defer { try? handle.close() }
          var data = Data()
          while true {
            try Task.checkCancellation()
            let remaining = DocumentContentPolicy.maximumSourceBytes - data.count
            let chunk = try handle.read(upToCount: min(64 * 1024, remaining + 1)) ?? Data()
            if chunk.isEmpty { break }
            guard chunk.count <= remaining else { throw ReadDocumentFailure.sourceTooLarge }
            data.append(chunk)
          }
          return (path, data)
        }
      }
      let (resolvedPath, data) = try await withTaskCancellationHandler {
        try await readTask.value
      } onCancel: {
        readTask.cancel()
      }
      path = resolvedPath
      try Task.checkCancellation()
      let markdown: String
      do {
        markdown = try await converter.markdown(from: data)
      } catch is CancellationError {
        throw CancellationError()
      } catch DocumentMarkdownConversionError.needsOCR {
        throw ReadDocumentFailure.needsOCR
      } catch {
        throw ReadDocumentFailure.conversionFailed
      }
      try Task.checkCancellation()
      let content = try ReadDocumentContent(path: resolvedPath, markdown: markdown)
      try Task.checkCancellation()
      return .readDocument(.success(content))
    } catch {
      return .readDocument(.failed(path: path, reason: failure(for: error)))
    }
  }

  private func failure(for error: Error) -> ReadDocumentFailure {
    if let failure = error as? ReadDocumentFailure { return failure }
    if error is CancellationError { return .file(.cancelled) }
    if error is WorkspacePathResolutionError {
      return .file(ToolResultFailureMapper.reason(from: error))
    }
    if ToolResultFailureMapper.isFileNotFound(error) {
      return .file(.fileNotFound(path: nil, suggestions: []))
    }
    if ToolResultFailureMapper.reason(from: error) == .permissionDenied {
      return .file(.permissionDenied)
    }
    return .unreadableFile
  }
}
