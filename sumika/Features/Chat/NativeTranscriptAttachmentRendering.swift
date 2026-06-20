import AppKit
import ImageIO
import SumikaCore

enum NativeTranscriptAttachmentPreviewMetrics {
  static let imageSize = NSSize(width: 180, height: 120)
  static let maxImagePixelSize = Int(max(imageSize.width, imageSize.height) * 2)
  static let textHeight: CGFloat = 32
  static let imageHeight: CGFloat = imageSize.height + 18
  static let itemSpacing: CGFloat = 6

  static func height(for attachments: [ChatAttachment]) -> CGFloat {
    guard !attachments.isEmpty else {
      return 0
    }
    let contentHeight = attachments.reduce(CGFloat(0)) { total, attachment in
      switch attachment.kind {
      case .image:
        total + imageHeight
      case .text:
        total + textHeight
      }
    }
    return contentHeight + CGFloat(max(0, attachments.count - 1)) * itemSpacing
  }
}

struct NativeAttachmentThumbDescriptor: Equatable, Hashable, Sendable {
  var attachmentID: AttachmentID
  var kind: ChatAttachmentKind
  var contentSignature: String
  var maxPixelSize: Int

  init(attachment: ChatAttachment, maxPixelSize: Int) {
    attachmentID = attachment.id
    kind = attachment.kind
    contentSignature = attachment.contentSignature
    self.maxPixelSize = maxPixelSize
  }
}

private struct NativeLoadedAttachmentThumb: @unchecked Sendable {
  var image: NSImage?
}

@MainActor
final class NativeTranscriptAttachmentThumbnailStore {
  private let attachmentStore: ChatAttachmentStore
  private var thumbnailsByDescriptor: [NativeAttachmentThumbDescriptor: NSImage] = [:]
  private var failedDescriptors: Set<NativeAttachmentThumbDescriptor> = []
  private var inFlightDescriptors: Set<NativeAttachmentThumbDescriptor> = []

  init(attachmentStore: ChatAttachmentStore = ChatAttachmentStore()) {
    self.attachmentStore = attachmentStore
  }

  var cachedEntryCount: Int {
    thumbnailsByDescriptor.count
  }

  func thumbnail(for attachment: ChatAttachment, maxPixelSize: Int) -> NSImage? {
    let descriptor = NativeAttachmentThumbDescriptor(
      attachment: attachment,
      maxPixelSize: maxPixelSize
    )
    return thumbnailsByDescriptor[descriptor]
  }

  func imageURL(for attachment: ChatAttachment) -> URL? {
    guard attachment.kind == .image else {
      return nil
    }
    return try? attachmentStore.localURL(for: attachment.id)
  }

  func requestThumbnail(
    rowID: String,
    attachment: ChatAttachment,
    maxPixelSize: Int,
    onUpdate: @escaping @MainActor (String) -> Void
  ) {
    guard attachment.kind == .image else {
      return
    }
    let descriptor = NativeAttachmentThumbDescriptor(
      attachment: attachment,
      maxPixelSize: maxPixelSize
    )
    guard thumbnailsByDescriptor[descriptor] == nil,
      !failedDescriptors.contains(descriptor),
      !inFlightDescriptors.contains(descriptor)
    else {
      return
    }

    inFlightDescriptors.insert(descriptor)
    let store = attachmentStore
    Task { [weak self] in
      let loaded = await Task.detached(priority: .userInitiated) {
        let url = try? store.localURL(for: descriptor.attachmentID)
        return NativeLoadedAttachmentThumb(
          image: NativeTranscriptImageFileLoader.thumbnailImage(
            from: url,
            maxPixelSize: CGFloat(descriptor.maxPixelSize)
          ))
      }.value

      await MainActor.run {
        guard let self else {
          return
        }
        self.inFlightDescriptors.remove(descriptor)
        if let image = loaded.image {
          self.thumbnailsByDescriptor[descriptor] = image
          onUpdate(rowID)
        } else {
          self.failedDescriptors.insert(descriptor)
        }
      }
    }
  }

  func prune(activeDescriptors: Set<NativeAttachmentThumbDescriptor>) {
    thumbnailsByDescriptor = thumbnailsByDescriptor.filter { activeDescriptors.contains($0.key) }
    failedDescriptors = failedDescriptors.intersection(activeDescriptors)
    inFlightDescriptors = inFlightDescriptors.intersection(activeDescriptors)
  }
}

enum NativeTranscriptImageFileLoader {
  nonisolated static func thumbnailImage(from url: URL?, maxPixelSize: CGFloat) -> NSImage? {
    guard let url else {
      return nil
    }
    guard
      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let cgImage = CGImageSourceCreateThumbnailAtIndex(
        source,
        0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: Int(maxPixelSize),
        ] as CFDictionary
      )
    else {
      return nil
    }
    return NSImage(cgImage: cgImage, size: .zero)
  }
}
