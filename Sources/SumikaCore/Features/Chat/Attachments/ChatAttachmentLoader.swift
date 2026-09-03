import Foundation

package protocol DocumentMarkdownConverting: Sendable {
  func markdown(from data: Data) async throws -> String
}

package enum DocumentMarkdownConversionError: Error {
  case needsOCR
}

package protocol ChatAttachmentLoading: Sendable {
  func loadAttachments(
    from urls: [URL],
    existingAttachments: [ChatAttachment]
  ) async throws -> [ChatAttachment]
}

struct AttachmentFileAccess: Sendable {
  private let startAccessingSecurityScopedResource: @Sendable (URL) -> Bool
  private let stopAccessingSecurityScopedResource: @Sendable (URL) -> Void
  private let fileSize: @Sendable (URL) throws -> Int?
  private let loadData: @Sendable (URL) throws -> Data

  init(
    startAccessingSecurityScopedResource: @escaping @Sendable (URL) -> Bool,
    stopAccessingSecurityScopedResource: @escaping @Sendable (URL) -> Void,
    fileSize: @escaping @Sendable (URL) throws -> Int?,
    readData: @escaping @Sendable (URL) throws -> Data
  ) {
    self.startAccessingSecurityScopedResource = startAccessingSecurityScopedResource
    self.stopAccessingSecurityScopedResource = stopAccessingSecurityScopedResource
    self.fileSize = fileSize
    self.loadData = readData
  }

  static let live = AttachmentFileAccess(
    startAccessingSecurityScopedResource: { url in
      #if canImport(Darwin)
        url.startAccessingSecurityScopedResource()
      #else
        false
      #endif
    },
    stopAccessingSecurityScopedResource: { url in
      #if canImport(Darwin)
        url.stopAccessingSecurityScopedResource()
      #endif
    },
    fileSize: { url in
      try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    },
    readData: { url in
      try Data(contentsOf: url)
    }
  )

  func readData(from url: URL, maximumBytes: Int) async throws -> Data {
    try Task.checkCancellation()
    let readTask = Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      let didStartSecurityScope = startAccessingSecurityScopedResource(url)
      defer {
        if didStartSecurityScope {
          stopAccessingSecurityScopedResource(url)
        }
      }

      let fileName = url.lastPathComponent
      guard let sourceByteSize = try fileSize(url) else {
        throw ChatAttachmentError.fileSizeUnavailable(fileName)
      }
      guard sourceByteSize <= maximumBytes else {
        throw ChatAttachmentError.fileTooLarge(fileName, maximumBytes)
      }

      let data = try loadData(url)
      try Task.checkCancellation()
      guard data.count <= maximumBytes else {
        throw ChatAttachmentError.fileTooLarge(fileName, maximumBytes)
      }
      return data
    }
    return try await withTaskCancellationHandler {
      let data = try await readTask.value
      try Task.checkCancellation()
      return data
    } onCancel: {
      readTask.cancel()
    }
  }
}

package struct ChatAttachmentLoader: ChatAttachmentLoading {
  private let attachmentStore: ChatAttachmentStore
  private let documentMarkdownConverter: (any DocumentMarkdownConverting)?
  private let fileAccess: AttachmentFileAccess

  package init(
    attachmentStore: ChatAttachmentStore = ChatAttachmentStore(),
    documentMarkdownConverter: (any DocumentMarkdownConverting)? = nil
  ) {
    self.init(
      attachmentStore: attachmentStore,
      documentMarkdownConverter: documentMarkdownConverter,
      fileAccess: .live
    )
  }

  init(
    attachmentStore: ChatAttachmentStore = ChatAttachmentStore(),
    documentMarkdownConverter: (any DocumentMarkdownConverting)? = nil,
    fileAccess: AttachmentFileAccess
  ) {
    self.attachmentStore = attachmentStore
    self.documentMarkdownConverter = documentMarkdownConverter
    self.fileAccess = fileAccess
  }

  package func loadAttachments(
    from urls: [URL],
    existingAttachments: [ChatAttachment]
  ) async throws -> [ChatAttachment] {
    let remainingSlots = ChatAttachmentLimits.maxAttachmentCount - existingAttachments.count
    guard urls.count <= remainingSlots else {
      throw ChatAttachmentError.tooManyFiles(ChatAttachmentLimits.maxAttachmentCount)
    }

    let existingNames = Set(existingAttachments.map(\.displayName))
    var attachments: [ChatAttachment] = []
    do {
      for url in urls {
        try Task.checkCancellation()
        guard !existingNames.contains(url.lastPathComponent) else {
          continue
        }

        attachments.append(try await readAttachment(from: url))
      }
      try Task.checkCancellation()
      try ChatAttachmentLimits.validateContent(of: existingAttachments + attachments)
      return attachments
    } catch {
      for attachment in attachments {
        await attachmentStore.removeStoredAttachment(attachment)
      }
      throw error
    }
  }

  private func readAttachment(from url: URL) async throws -> ChatAttachment {
    let fileName = url.lastPathComponent
    let fileExtension = url.pathExtension.lowercased()
    if ChatAttachmentLimits.supportedImageFileExtensions.contains(fileExtension) {
      return try await readImageAttachment(from: url)
    }
    if ChatAttachmentLimits.supportedTextFileExtensions.contains(fileExtension) {
      return try await readTextAttachment(from: url)
    }
    if ChatAttachmentLimits.supportedDocumentFileExtensions.contains(fileExtension),
      let documentMarkdownConverter
    {
      return try await readDocumentAttachment(
        from: url,
        converter: documentMarkdownConverter
      )
    }
    throw ChatAttachmentError.unsupportedFileType(fileName)
  }

  private func readTextAttachment(from url: URL) async throws -> ChatAttachment {
    let fileName = url.lastPathComponent
    let data = try await fileAccess.readData(
      from: url,
      maximumBytes: ChatAttachmentLimits.maxTextFileBytes
    )
    guard let content = String(data: data, encoding: .utf8) else {
      throw ChatAttachmentError.unreadableText(fileName)
    }
    return try await storeTextAttachment(
      content: content,
      originalData: data,
      fileName: fileName
    )
  }

  private func readDocumentAttachment(
    from url: URL,
    converter: any DocumentMarkdownConverting
  ) async throws -> ChatAttachment {
    let fileName = url.lastPathComponent
    let data = try await fileAccess.readData(
      from: url,
      maximumBytes: ChatAttachmentLimits.maxDocumentFileBytes
    )
    try Task.checkCancellation()

    let markdown: String
    do {
      markdown = try await converter.markdown(from: data)
    } catch is CancellationError {
      throw CancellationError()
    } catch DocumentMarkdownConversionError.needsOCR {
      throw ChatAttachmentError.documentNeedsOCR(fileName)
    } catch {
      throw ChatAttachmentError.documentConversionFailed(fileName)
    }

    try Task.checkCancellation()
    guard markdown.utf8.count <= ChatAttachmentLimits.maxConvertedDocumentBytes else {
      throw ChatAttachmentError.convertedDocumentTooLarge(
        fileName,
        ChatAttachmentLimits.maxConvertedDocumentBytes
      )
    }

    return try await storeTextAttachment(
      content: markdown,
      originalData: data,
      fileName: fileName
    )
  }

  private func storeTextAttachment(
    content: String,
    originalData: Data,
    fileName: String
  ) async throws -> ChatAttachment {
    let id = AttachmentID()
    _ = try await attachmentStore.storeFile(
      data: originalData,
      id: id,
      displayName: fileName
    )
    return ChatAttachment(
      id: id,
      displayName: fileName,
      payload: .text(
        TextAttachmentPayload(
          content: content,
          byteSize: originalData.count,
          contentSHA256: ChatAttachmentStore.contentSHA256(for: originalData)
        )
      )
    )
  }

  private func readImageAttachment(from url: URL) async throws -> ChatAttachment {
    let fileName = url.lastPathComponent
    let fileExtension = url.pathExtension.lowercased()
    let imageData = try await fileAccess.readData(
      from: url,
      maximumBytes: ChatAttachmentLimits.maxImageFileBytes
    )

    let mimeType = mimeType(forExtension: fileExtension) ?? "image"
    let contentSHA256 = ChatAttachmentStore.contentSHA256(for: imageData)
    let id = AttachmentID()
    _ = try await attachmentStore.storeFile(data: imageData, id: id, displayName: fileName)
    return ChatAttachment(
      id: id,
      displayName: fileName,
      payload: .image(
        ImageAttachmentPayload(
          mimeType: mimeType,
          byteSize: imageData.count,
          contentSHA256: contentSHA256
        )
      )
    )
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
