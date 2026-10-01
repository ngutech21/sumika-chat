import AppKit
import SumikaCore
import SwiftUI

struct AttachmentPreview: View {
  let attachment: ChatAttachment
  let imageLoader: AttachmentImageLoader
  var canRemove = false
  var onRemove: ((ChatAttachment.ID) -> Void)?
  @Environment(\.displayScale) private var displayScale
  @State private var isImagePreviewPresented = false
  @State private var thumbnailImage: NSImage?

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
    .help(attachment.displayName)
    .accessibilityElement(children: .contain)
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
        AttachmentImagePopover(attachment: attachment, imageLoader: imageLoader)
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

  private var thumbnailLoadKey: AttachmentImageRequest {
    AttachmentImageRequest(
      attachment: attachment,
      maxPixelSize: Int(
        (max(thumbnailSize.width, thumbnailSize.height) * displayScale).rounded(.up))
    )
  }

  private func loadImagePreview(for key: AttachmentImageRequest) async {
    guard !Task.isCancelled else {
      return
    }
    thumbnailImage = nil
    let image = await imageLoader.image(for: key)
    guard !Task.isCancelled else {
      return
    }
    thumbnailImage = image
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

struct AttachmentImagePopover: View {
  let attachment: ChatAttachment
  let imageLoader: AttachmentImageLoader
  @Environment(\.displayScale) private var displayScale
  @State private var image: NSImage?
  @State private var isLoading = true
  private let maximumSize = CGSize(width: 900, height: 700)

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let image {
        Image(nsImage: image)
          .resizable()
          .scaledToFit()
          .frame(width: fittedSize(for: image).width, height: fittedSize(for: image).height)
          .accessibilityLabel(attachment.displayName)
      } else if isLoading {
        ProgressView("Loading Image")
          .frame(width: 360, height: 240)
      } else {
        ContentUnavailableView("Image Unavailable", systemImage: "photo")
          .frame(width: 360, height: 240)
      }

      Text(attachment.displayName)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .padding(12)
    .frame(minWidth: 320, minHeight: 220)
    .task(id: imageRequest) {
      guard !Task.isCancelled else {
        return
      }
      image = nil
      isLoading = true
      let loadedImage = await imageLoader.image(for: imageRequest)
      guard !Task.isCancelled else {
        return
      }
      image = loadedImage
      isLoading = false
    }
  }

  private var imageRequest: AttachmentImageRequest {
    AttachmentImageRequest(
      attachment: attachment,
      maxPixelSize: Int((max(maximumSize.width, maximumSize.height) * displayScale).rounded(.up))
    )
  }

  private func fittedSize(for image: NSImage) -> CGSize {
    let scale = min(maximumSize.width / image.size.width, maximumSize.height / image.size.height, 1)
    return CGSize(width: image.size.width * scale, height: image.size.height * scale)
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
