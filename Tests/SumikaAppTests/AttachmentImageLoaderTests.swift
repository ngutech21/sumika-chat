import AppKit
import ImageIO
import SumikaTestSupport
import Testing
import UniformTypeIdentifiers

@testable import SumikaApp
@testable import SumikaCore

@MainActor
@Suite(.serialized, TemporaryDirectoryTrait())
struct AttachmentImageLoaderTests {
  @Test(arguments: [68, 360, 1_800])
  func downsamplingBoundsDecodedPixels(maxPixelSize: Int) async throws {
    let (store, attachment) = try await storedImage(width: 2_400, height: 1_200)
    let image = await AttachmentImageLoader(
      attachmentLifecycle: ChatAttachmentLifecycle(store: store)
    ).image(
      for: AttachmentImageRequest(attachment: attachment, maxPixelSize: maxPixelSize))
    let decoded = try #require(image?.cgImage(forProposedRect: nil, context: nil, hints: nil))

    #expect(decoded.width == maxPixelSize)
    #expect(decoded.height == maxPixelSize / 2)
  }

  @Test(arguments: [1, 6, 8])
  func downsamplingPreservesEXIFOrientation(orientation: Int) async throws {
    let (store, attachment) = try await storedImage(
      width: 80, height: 40, orientation: orientation)
    let image = await AttachmentImageLoader(
      attachmentLifecycle: ChatAttachmentLifecycle(store: store)
    ).image(
      for: AttachmentImageRequest(attachment: attachment, maxPixelSize: 40))
    let decoded = try #require(image?.cgImage(forProposedRect: nil, context: nil, hints: nil))

    #expect(decoded.width == (orientation == 1 ? 40 : 20))
    #expect(decoded.height == (orientation == 1 ? 20 : 40))
  }

  @Test
  func missingAndCorruptImagesAreUnavailable() async throws {
    let (store, attachment) = try await storedImage(width: 80, height: 40)
    let request = AttachmentImageRequest(attachment: attachment, maxPixelSize: 40)
    let loader = AttachmentImageLoader(attachmentLifecycle: ChatAttachmentLifecycle(store: store))
    let url = try store.localURL(for: attachment.id)
    try Data("not an image".utf8).write(to: url)
    #expect(await loader.image(for: request) == nil)

    try FileManager.default.removeItem(at: url)
    #expect(await loader.image(for: request) == nil)
  }

  @Test
  func textAttachmentsAreNotDecodedAsImages() async throws {
    let (store, attachment) = try await storedImage(width: 80, height: 40)
    let text = ChatAttachment(
      id: attachment.id,
      displayName: "notes.txt",
      payload: .text(TextAttachmentPayload(content: "Notes", byteSize: 5, contentSHA256: "text")))
    let image = await AttachmentImageLoader(
      attachmentLifecycle: ChatAttachmentLifecycle(store: store)
    ).image(
      for: AttachmentImageRequest(attachment: text, maxPixelSize: 40))

    #expect(image == nil)
  }

  @Test(arguments: [0, -1])
  func invalidPixelLimitsAreRejected(maxPixelSize: Int) async throws {
    let (store, attachment) = try await storedImage(width: 80, height: 40)
    let image = await AttachmentImageLoader(
      attachmentLifecycle: ChatAttachmentLifecycle(store: store)
    ).image(
      for: AttachmentImageRequest(attachment: attachment, maxPixelSize: maxPixelSize))

    #expect(image == nil)
  }

  @Test
  func cancelledLoadDoesNotPublishAnImage() async throws {
    let (store, attachment) = try await storedImage(width: 80, height: 40)
    let loader = AttachmentImageLoader(attachmentLifecycle: ChatAttachmentLifecycle(store: store))
    let request = AttachmentImageRequest(attachment: attachment, maxPixelSize: 40)
    let task = Task { await loader.image(for: request) != nil }
    task.cancel()

    #expect(await task.value == false)
  }

  @Test
  func pruningCancelsOldRequestsWithoutDiscardingReplacementLoads() async throws {
    let (store, attachment) = try await storedImage(width: 80, height: 40)
    let thumbnails = NativeTranscriptAttachmentThumbnailStore(
      imageLoader: AttachmentImageLoader(attachmentLifecycle: ChatAttachmentLifecycle(store: store))
    )
    var updatedRows: [String] = []
    thumbnails.requestThumbnail(rowID: "removed", attachment: attachment, maxPixelSize: 40) {
      updatedRows.append($0)
    }
    thumbnails.prune(activeDescriptors: [])
    thumbnails.requestThumbnail(rowID: "current", attachment: attachment, maxPixelSize: 40) {
      updatedRows.append($0)
    }
    try await withTestTimeout {
      while await MainActor.run(body: { updatedRows.isEmpty }) {
        try await Task.sleep(for: .milliseconds(10))
      }
    }

    #expect(updatedRows == ["current"])
    #expect(thumbnails.thumbnail(for: attachment, maxPixelSize: 40) != nil)
    #expect(thumbnails.thumbnail(for: attachment, maxPixelSize: 80) == nil)
    thumbnails.prune(activeDescriptors: [])
    #expect(thumbnails.thumbnail(for: attachment, maxPixelSize: 40) == nil)
  }

  private func storedImage(width: Int, height: Int, orientation: Int = 1) async throws
    -> (ChatAttachmentStore, ChatAttachment)
  {
    let context = try #require(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(
      CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(
      destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
    try #require(CGImageDestinationFinalize(destination))
    let store = ChatAttachmentStore(baseURL: try scopedTemporaryDirectory())
    let attachment = ChatAttachment(
      displayName: "image.jpg",
      payload: .image(
        ImageAttachmentPayload(
          mimeType: "image/jpeg", byteSize: data.length,
          contentSHA256: ChatAttachmentStore.contentSHA256(for: data as Data))))
    _ = try await store.storeFile(
      data: data as Data, id: attachment.id, displayName: attachment.displayName)
    return (store, attachment)
  }
}
