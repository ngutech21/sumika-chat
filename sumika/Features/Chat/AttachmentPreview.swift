import AppKit
import ImageIO
import SumikaCore
import SwiftUI

struct AttachmentPreview: View {
  enum Style {
    case pending
    case sent

    var thumbnailSize: CGSize {
      switch self {
      case .pending:
        CGSize(width: 34, height: 34)
      case .sent:
        CGSize(width: 96, height: 64)
      }
    }

    var labelMaxWidth: CGFloat {
      switch self {
      case .pending:
        180
      case .sent:
        160
      }
    }
  }

  let attachment: ChatAttachment
  let style: Style
  var canRemove = false
  var onRemove: ((ChatAttachment.ID) -> Void)?
  @State private var isImagePreviewPresented = false
  private let attachmentStore = ChatAttachmentStore()

  var body: some View {
    Group {
      if usesVerticalImageLayout {
        VStack(alignment: .leading, spacing: 0) {
          thumbnail
          attachmentName
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
        }
      } else {
        HStack(spacing: 7) {
          thumbnail
          attachmentName

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
      }
    }
    .padding(.horizontal, horizontalPadding)
    .padding(.vertical, verticalPadding)
    .background(Color.secondary.opacity(0.12))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay {
      if usesVerticalImageLayout {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
      }
    }
    .help(attachment.displayPath)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel)
  }

  private var attachmentName: some View {
    Group {
      if usesVerticalImageLayout {
        attachmentNameText
          .frame(width: style.thumbnailSize.width, alignment: .leading)
      } else {
        attachmentNameText
          .frame(maxWidth: style.labelMaxWidth, alignment: .leading)
      }
    }
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
          url: imageURL,
          size: style.thumbnailSize,
          showsInnerBorder: !usesVerticalImageLayout
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

  private var usesVerticalImageLayout: Bool {
    switch style {
    case .pending:
      false
    case .sent:
      attachment.kind == .image
    }
  }

  private var horizontalPadding: CGFloat {
    if usesVerticalImageLayout {
      return 0
    }
    return attachment.kind == .image ? 5 : 8
  }

  private var verticalPadding: CGFloat {
    if usesVerticalImageLayout {
      return 0
    }
    return attachment.kind == .image ? 5 : 6
  }

  private var imageURL: URL? {
    try? attachmentStore.localURL(for: attachment.id)
  }
}

private struct AttachmentThumbnail: View {
  let url: URL?
  let size: CGSize
  var showsInnerBorder = true

  var body: some View {
    Group {
      if let image = ImageFileLoader.thumbnailImage(
        from: url,
        maxPixelSize: max(size.width, size.height) * 2
      ) {
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

private enum ImageFileLoader {
  static func thumbnailImage(from url: URL?, maxPixelSize: CGFloat) -> NSImage? {
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
