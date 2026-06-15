import Foundation

public protocol ChatAttachmentLoading: Sendable {
  func loadAttachments(
    from urls: [URL],
    existingAttachments: [ChatAttachment]
  ) throws -> [ChatAttachment]

  func extractDroppedAttachments(from draft: String) -> DroppedAttachmentExtraction
}

public struct DroppedAttachmentExtraction: Equatable, Sendable {
  public var urls: [URL]
  public var cleanedDraft: String

  public init(urls: [URL] = [], cleanedDraft: String) {
    self.urls = urls
    self.cleanedDraft = cleanedDraft
  }
}

public struct ChatAttachmentLoader: ChatAttachmentLoading {
  private let attachmentStore: ChatAttachmentStore

  private static let droppedAttachmentRegex: NSRegularExpression? = {
    let extensions = ChatAttachmentLimits.supportedFileExtensions
      .sorted { $0.count > $1.count }
      .map(NSRegularExpression.escapedPattern(for:))
      .joined(separator: "|")
    let pattern = #"file://[^\s]+|/[^\n\r\t]*?\.(?:"# + extensions + #")(?=\s|$)"#
    return try? NSRegularExpression(pattern: pattern)
  }()

  public init(attachmentStore: ChatAttachmentStore = ChatAttachmentStore()) {
    self.attachmentStore = attachmentStore
  }

  public func loadAttachments(
    from urls: [URL],
    existingAttachments: [ChatAttachment]
  ) throws -> [ChatAttachment] {
    let remainingSlots = ChatAttachmentLimits.maxAttachmentCount - existingAttachments.count
    guard urls.count <= remainingSlots else {
      throw ChatAttachmentError.tooManyFiles(ChatAttachmentLimits.maxAttachmentCount)
    }

    let existingNames = Set(existingAttachments.map(\.displayName))
    return try urls.compactMap { url -> ChatAttachment? in
      guard !existingNames.contains(url.lastPathComponent) else {
        return nil
      }

      return try readTextAttachment(from: url)
    }
  }

  public func extractDroppedAttachments(from draft: String) -> DroppedAttachmentExtraction {
    guard let regex = Self.droppedAttachmentRegex else {
      return DroppedAttachmentExtraction(cleanedDraft: draft)
    }

    let range = NSRange(draft.startIndex..<draft.endIndex, in: draft)
    let matches = regex.matches(in: draft, range: range)
    guard !matches.isEmpty else {
      return DroppedAttachmentExtraction(cleanedDraft: draft)
    }

    var urls: [URL] = []
    var rangesToRemove: [Range<String.Index>] = []

    for match in matches {
      guard let matchRange = Range(match.range, in: draft) else {
        continue
      }

      let rawPath = String(draft[matchRange])
      guard let url = attachmentURL(fromDroppedPath: rawPath), isSupportedAttachmentURL(url) else {
        continue
      }

      urls.append(url)
      rangesToRemove.append(matchRange)
    }

    guard !urls.isEmpty else {
      return DroppedAttachmentExtraction(cleanedDraft: draft)
    }

    var cleanedDraft = draft
    for range in rangesToRemove.reversed() {
      cleanedDraft.removeSubrange(range)
    }

    return DroppedAttachmentExtraction(
      urls: urls,
      cleanedDraft: normalizeDraftAfterRemovingAttachmentPaths(cleanedDraft)
    )
  }

  private func readTextAttachment(from url: URL) throws -> ChatAttachment {
    try withSecurityScopedAccess(to: url) {
      let fileName = url.lastPathComponent
      let fileExtension = url.pathExtension.lowercased()
      if ChatAttachmentLimits.supportedImageFileExtensions.contains(fileExtension) {
        return try readImageAttachment(from: url)
      }

      guard ChatAttachmentLimits.supportedTextFileExtensions.contains(fileExtension) else {
        throw ChatAttachmentError.unsupportedFileType(fileName)
      }

      let fileSize = try fileSize(for: url)
      guard fileSize <= ChatAttachmentLimits.maxTextFileBytes else {
        throw ChatAttachmentError.fileTooLarge(fileName, ChatAttachmentLimits.maxTextFileBytes)
      }

      let data = try Data(contentsOf: url)
      guard let content = String(data: data, encoding: .utf8) else {
        throw ChatAttachmentError.unreadableText(fileName)
      }
      let id = AttachmentID()
      _ = try attachmentStore.storeFile(from: url, id: id, displayName: fileName)

      return ChatAttachment(
        id: id,
        displayName: fileName,
        payload: .text(
          TextAttachmentPayload(
            content: content,
            byteSize: fileSize,
            contentSHA256: ChatAttachmentStore.contentSHA256(for: data)
          )
        )
      )
    }
  }

  private func readImageAttachment(from url: URL) throws -> ChatAttachment {
    let fileName = url.lastPathComponent
    let fileExtension = url.pathExtension.lowercased()
    let fileSize = try fileSize(for: url)
    guard fileSize <= ChatAttachmentLimits.maxImageFileBytes else {
      throw ChatAttachmentError.fileTooLarge(fileName, ChatAttachmentLimits.maxImageFileBytes)
    }

    let imageData = try Data(contentsOf: url)

    let metadata = ChatAttachmentMetadata(
      mimeType: mimeType(forExtension: fileExtension),
      byteCount: fileSize,
      contentSHA256: ChatAttachmentStore.contentSHA256(for: imageData)
    )
    let id = AttachmentID()
    _ = try attachmentStore.storeFile(from: url, id: id, displayName: fileName)
    return ChatAttachment(
      id: id,
      displayName: fileName,
      payload: .image(
        ImageAttachmentPayload(
          mimeType: metadata.mimeType ?? "image",
          byteSize: fileSize,
          contentSHA256: metadata.contentSHA256 ?? ""
        )
      )
    )
  }

  private func withSecurityScopedAccess<T>(
    to url: URL,
    _ body: () throws -> T
  ) throws -> T {
    #if canImport(Darwin)
      let didStartSecurityScope = url.startAccessingSecurityScopedResource()
      defer {
        if didStartSecurityScope {
          url.stopAccessingSecurityScopedResource()
        }
      }
    #endif
    return try body()
  }

  private func fileSize(for url: URL) throws -> Int {
    let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey])
    return resourceValues.fileSize ?? 0
  }

  private func mimeType(forExtension fileExtension: String) -> String? {
    switch fileExtension {
    case "jpg", "jpeg":
      "image/jpeg"
    case "png":
      "image/png"
    case "webp":
      "image/webp"
    case "css":
      "text/css"
    case "csv":
      "text/csv"
    case "html":
      "text/html"
    case "json":
      "application/json"
    case "md":
      "text/markdown"
    case "xml":
      "application/xml"
    case "yaml", "yml":
      "application/yaml"
    default:
      fileExtension.isEmpty ? nil : "text/plain"
    }
  }

  private func attachmentURL(fromDroppedPath path: String) -> URL? {
    if path.hasPrefix("file://") {
      return URL(string: path)?.standardizedFileURL
    }

    return URL(filePath: path).standardizedFileURL
  }

  private func isSupportedAttachmentURL(_ url: URL) -> Bool {
    let path = url.path(percentEncoded: false)
    let fileExtension = url.pathExtension.lowercased()
    var isDirectory: ObjCBool = false

    let hasSupportedExtension =
      ChatAttachmentLimits.supportedTextFileExtensions.contains(fileExtension)
      || ChatAttachmentLimits.supportedImageFileExtensions.contains(fileExtension)

    return hasSupportedExtension
      && FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
      && !isDirectory.boolValue
  }

  private func normalizeDraftAfterRemovingAttachmentPaths(_ text: String) -> String {
    var cleaned =
      text
      .replacingOccurrences(of: " \n", with: "\n")
      .replacingOccurrences(of: "\n ", with: "\n")

    while cleaned.contains("  ") {
      cleaned = cleaned.replacingOccurrences(of: "  ", with: " ")
    }

    return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
