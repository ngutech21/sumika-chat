import AppKit
import ImageIO
import SumikaCore

nonisolated struct AttachmentImageRequest: Hashable, Sendable {
  let attachmentID: AttachmentID
  let kind: ChatAttachmentKind
  let contentSignature: String
  let maxPixelSize: Int

  init(attachment: ChatAttachment, maxPixelSize: Int) {
    attachmentID = attachment.id
    kind = attachment.kind
    contentSignature = attachment.contentSignature
    self.maxPixelSize = maxPixelSize
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(attachmentID)
    hasher.combine(kind)
    hasher.combine(contentSignature)
    hasher.combine(maxPixelSize)
  }
}

struct AttachmentImageLoader: Sendable {
  private let attachmentLifecycle: ChatAttachmentLifecycle

  init(attachmentLifecycle: ChatAttachmentLifecycle) {
    self.attachmentLifecycle = attachmentLifecycle
  }

  func image(for request: AttachmentImageRequest) async -> NSImage? {
    guard let image = try? await decodedImage(for: request), !Task.isCancelled else {
      return nil
    }
    return NSImage(cgImage: image, size: .zero)
  }

  // Explicitly leave MainActor even with NonisolatedNonsendingByDefault enabled.
  @concurrent
  private func decodedImage(for request: AttachmentImageRequest) async throws -> CGImage? {
    try Task.checkCancellation()
    guard request.kind == .image, request.maxPixelSize > 0 else {
      return nil
    }
    let url = try await attachmentLifecycle.localURL(for: request.attachmentID)
    try Task.checkCancellation()
    guard
      let source = CGImageSourceCreateWithURL(
        url as CFURL,
        [kCGImageSourceShouldCache: false] as CFDictionary
      )
    else {
      return nil
    }
    try Task.checkCancellation()
    let image = CGImageSourceCreateThumbnailAtIndex(
      source,
      0,
      [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: request.maxPixelSize,
        kCGImageSourceShouldCacheImmediately: true,
      ] as CFDictionary
    )
    try Task.checkCancellation()
    return image
  }
}
