import AppKit
import ImageIO
import SumikaCore
import SwiftUI

struct AttachmentPreview: View {
  let attachment: ChatAttachment
  var canRemove = false
  var onRemove: ((ChatAttachment.ID) -> Void)?
  @State private var isImagePreviewPresented = false
  @State private var imageURL: URL?
  @State private var thumbnailImage: NSImage?
  private let attachmentStore = ChatAttachmentStore()

  var body: some View {
    HStack(spacing: 7) {
      thumbnail
      if attachment.kind != .image {
        attachmentName
      }

      if let onRemove {
        Button {
          onRemove(attachment.id)
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .disabled(!canRemove)
        .help("Remove")
        .accessibilityLabel("Remove \(attachment.displayName)")
      }
    }
    .padding(.horizontal, horizontalPadding)
    .padding(.vertical, verticalPadding)
    .background(Color.secondary.opacity(0.12))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .help(attachment.displayPath)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel)
    .task(id: thumbnailLoadKey) {
      await loadImagePreview(for: thumbnailLoadKey)
    }
  }

  private var attachmentName: some View {
    attachmentNameText
      .frame(maxWidth: 180, alignment: .leading)
  }

  private var attachmentNameText: some View {
    Text(attachment.displayName)
      .font(.caption)
      .lineLimit(1)
      .truncationMode(.middle)
  }

  @ViewBuilder
  private var thumbnail: some View {
    if attachment.kind == .image {
      Button {
        isImagePreviewPresented = true
      } label: {
        AttachmentThumbnail(
          image: thumbnailImage,
          size: thumbnailSize
        )
      }
      .buttonStyle(.plain)
      .help("Show full image")
      .accessibilityLabel("Show \(attachment.displayName)")
      .popover(isPresented: $isImagePreviewPresented, arrowEdge: .leading) {
        AttachmentImagePopover(url: imageURL, displayName: attachment.displayName)
      }
    } else {
      Image(systemName: attachment.kind.systemImageName)
        .foregroundStyle(.secondary)
        .frame(width: 16, height: 16)
    }
  }

  private var accessibilityLabel: String {
    switch attachment.kind {
    case .text:
      "Attached file \(attachment.displayName)"
    case .image:
      "Attached image \(attachment.displayName)"
    }
  }

  private var horizontalPadding: CGFloat {
    attachment.kind == .image ? 5 : 8
  }

  private var verticalPadding: CGFloat {
    attachment.kind == .image ? 5 : 6
  }

  private var thumbnailSize: CGSize {
    CGSize(width: 34, height: 34)
  }

  private var thumbnailLoadKey: AttachmentThumbnailLoadKey {
    AttachmentThumbnailLoadKey(
      attachmentID: attachment.id,
      kind: attachment.kind,
      maxPixelSize: Int(max(thumbnailSize.width, thumbnailSize.height) * 2)
    )
  }

  private func loadImagePreview(for key: AttachmentThumbnailLoadKey) async {
    guard key.kind == .image else {
      imageURL = nil
      thumbnailImage = nil
      return
    }

    let store = attachmentStore
    let loaded = await Task.detached(priority: .userInitiated) {
      do {
        let url = try store.localURL(for: key.attachmentID)
        let image = ImageFileLoader.thumbnailImage(
          from: url,
          maxPixelSize: CGFloat(key.maxPixelSize)
        )
        return LoadedAttachmentThumbnail(url: url, image: image)
      } catch {
        return LoadedAttachmentThumbnail(url: nil, image: nil)
      }
    }.value

    guard !Task.isCancelled else {
      return
    }
    imageURL = loaded.url
    thumbnailImage = loaded.image
  }
}

private struct AttachmentThumbnail: View {
  let image: NSImage?
  let size: CGSize
  var showsInnerBorder = true

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image)
          .resizable()
          .scaledToFill()
      } else {
        Image(systemName: "photo")
          .font(.body)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(Color.secondary.opacity(0.08))
      }
    }
    .frame(width: size.width, height: size.height)
    .clipped()
    .overlay {
      if showsInnerBorder {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
      }
    }
  }
}

private struct AttachmentImagePopover: View {
  let url: URL?
  let displayName: String

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let url, let image = NSImage(contentsOf: url) {
        Image(nsImage: image)
          .resizable()
          .scaledToFit()
          .frame(maxWidth: 900, maxHeight: 700)
      } else {
        ContentUnavailableView("Image Unavailable", systemImage: "photo")
          .frame(width: 360, height: 240)
      }

      Text(displayName)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .padding(12)
    .frame(minWidth: 320, minHeight: 220)
  }
}

private struct AttachmentThumbnailLoadKey: Equatable {
  let attachmentID: ChatAttachment.ID
  let kind: ChatAttachmentKind
  let maxPixelSize: Int
}

private struct LoadedAttachmentThumbnail: @unchecked Sendable {
  let url: URL?
  let image: NSImage?
}

private enum ImageFileLoader {
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

extension ChatAttachmentKind {
  var systemImageName: String {
    switch self {
    case .text:
      "doc.text"
    case .image:
      "photo"
    }
  }
}
