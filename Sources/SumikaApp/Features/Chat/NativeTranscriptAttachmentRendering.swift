import AppKit
import SumikaCore

enum NativeTranscriptAttachmentPreviewMetrics {
  static let imageSize = NSSize(width: 180, height: 120)
  static let maxImagePixelSize = Int(max(imageSize.width, imageSize.height) * 2)
  // Test-only; exercised through @testable import.
  // swiftlint:disable:next unused_declaration
  static let imageHeight: CGFloat = imageSize.height + 18
}

@MainActor
final class NativeTranscriptAttachmentThumbnailStore {
  private let imageLoader: AttachmentImageLoader
  private var thumbnailsByDescriptor: [AttachmentImageRequest: NSImage] = [:]
  private var failedDescriptors: Set<AttachmentImageRequest> = []
  private var inFlightLoads: [AttachmentImageRequest: Task<Void, Never>] = [:]

  init(imageLoader: AttachmentImageLoader) {
    self.imageLoader = imageLoader
  }

  deinit {
    for task in inFlightLoads.values {
      task.cancel()
    }
  }

  func thumbnail(for attachment: ChatAttachment, maxPixelSize: Int) -> NSImage? {
    let descriptor = AttachmentImageRequest(
      attachment: attachment,
      maxPixelSize: maxPixelSize
    )
    return thumbnailsByDescriptor[descriptor]
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
    let descriptor = AttachmentImageRequest(
      attachment: attachment,
      maxPixelSize: maxPixelSize
    )
    guard thumbnailsByDescriptor[descriptor] == nil,
      !failedDescriptors.contains(descriptor),
      inFlightLoads[descriptor] == nil
    else {
      return
    }

    let loader = imageLoader
    inFlightLoads[descriptor] = Task { [weak self] in
      let image = await loader.image(for: descriptor)
      guard !Task.isCancelled, let self else {
        return
      }
      self.inFlightLoads.removeValue(forKey: descriptor)
      if let image {
        self.thumbnailsByDescriptor[descriptor] = image
        onUpdate(rowID)
      } else {
        self.failedDescriptors.insert(descriptor)
      }
    }
  }

  func prune(activeDescriptors: Set<AttachmentImageRequest>) {
    thumbnailsByDescriptor = thumbnailsByDescriptor.filter { activeDescriptors.contains($0.key) }
    failedDescriptors = failedDescriptors.intersection(activeDescriptors)
    inFlightLoads = inFlightLoads.filter { descriptor, task in
      if activeDescriptors.contains(descriptor) {
        return true
      }
      task.cancel()
      return false
    }
  }
}
