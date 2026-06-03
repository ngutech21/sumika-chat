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
  public init() {}

  public func loadAttachments(
    from urls: [URL],
    existingAttachments: [ChatAttachment]
  ) throws -> [ChatAttachment] {
    let remainingSlots = ChatAttachmentLimits.maxAttachmentCount - existingAttachments.count
    guard urls.count <= remainingSlots else {
      throw ChatAttachmentError.tooManyFiles(ChatAttachmentLimits.maxAttachmentCount)
    }

    let existingPaths = Set(existingAttachments.map(\.displayPath))
    return try urls.compactMap { url -> ChatAttachment? in
      let path = url.path(percentEncoded: false)
      guard !existingPaths.contains(path) else {
        return nil
      }

      return try readTextAttachment(from: url)
    }
  }

  public func extractDroppedAttachments(from draft: String) -> DroppedAttachmentExtraction {
    let pattern = droppedAttachmentPathPattern()
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
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
    let didStartSecurityScope = url.startAccessingSecurityScopedResource()
    defer {
      if didStartSecurityScope {
        url.stopAccessingSecurityScopedResource()
      }
    }

    let fileName = url.lastPathComponent
    let fileExtension = url.pathExtension.lowercased()
    guard ChatAttachmentLimits.supportedTextFileExtensions.contains(fileExtension) else {
      throw ChatAttachmentError.unsupportedFileType(fileName)
    }

    let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey])
    let fileSize = resourceValues.fileSize ?? 0
    guard fileSize <= ChatAttachmentLimits.maxTextFileBytes else {
      throw ChatAttachmentError.fileTooLarge(fileName, ChatAttachmentLimits.maxTextFileBytes)
    }

    let data = try Data(contentsOf: url)
    guard let content = String(data: data, encoding: .utf8) else {
      throw ChatAttachmentError.unreadableText(fileName)
    }

    return ChatAttachment(
      url: url,
      displayName: fileName,
      kind: .text,
      content: content
    )
  }

  private func droppedAttachmentPathPattern() -> String {
    let extensions = ChatAttachmentLimits.supportedTextFileExtensions
      .sorted { $0.count > $1.count }
      .map(NSRegularExpression.escapedPattern(for:))
      .joined(separator: "|")
    return #"file://[^\s]+|/[^\n\r\t]*?\.(?:"# + extensions + #")(?=\s|$)"#
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

    return ChatAttachmentLimits.supportedTextFileExtensions.contains(fileExtension)
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
