import Foundation

package protocol ChatAttachmentLoading: Sendable {
  func loadAttachments(
    from urls: [URL],
    existingAttachments: [ChatAttachment]
  ) throws -> [ChatAttachment]
}

package struct ChatAttachmentLoader: ChatAttachmentLoading {
  private let attachmentStore: ChatAttachmentStore

  package init(attachmentStore: ChatAttachmentStore = ChatAttachmentStore()) {
    self.attachmentStore = attachmentStore
  }

  package func loadAttachments(
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
}
