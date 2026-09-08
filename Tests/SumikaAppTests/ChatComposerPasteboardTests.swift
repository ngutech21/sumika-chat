import AppKit
import Testing

@testable import SumikaApp

@MainActor
@Suite(.serialized)
struct ChatComposerPasteboardTests {
  @Test(arguments: [NSPasteboard.PasteboardType.tiff, .png])
  func commandVPastesImageThroughMenuValidation(type: NSPasteboard.PasteboardType) throws {
    let textView = Self.makeTextView()
    textView.string = "Keep this draft"
    var attachmentCount = 0
    textView.onPasteboardAttachments = { _ in
      attachmentCount += 1
      return true
    }

    try withGeneralPasteboardImage(type: type) {
      let menu = NSMenu(title: "Edit")
      let item = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
      item.target = textView
      menu.addItem(item)
      menu.update()

      #expect(item.isEnabled)
      #expect(attachmentCount == 0)
      let event = try #require(Self.pasteEvent(modifiers: .command))
      #expect(menu.performKeyEquivalent(with: event))
      #expect(attachmentCount == 1)
      #expect(textView.string == "Keep this draft")
    }
  }

  @Test(arguments: [false, true], [false, true])
  func imagePasteValidationRespectsComposerState(
    isEditable: Bool,
    canAcceptAttachments: Bool
  ) throws {
    let textView = Self.makeTextView()
    textView.isEditable = isEditable
    textView.canAcceptAttachments = canAcceptAttachments
    var attachmentCount = 0
    textView.onPasteboardAttachments = { _ in
      attachmentCount += 1
      return true
    }

    try withGeneralPasteboardImage(type: .tiff) {
      for action in [#selector(NSText.paste(_:)), #selector(NSTextView.pasteAsRichText(_:))] {
        let menu = NSMenu(title: "Edit")
        let item = NSMenuItem(title: "Paste", action: action, keyEquivalent: "v")
        item.target = textView
        menu.addItem(item)
        menu.update()
        #expect(item.isEnabled == (isEditable && canAcceptAttachments))
      }
      #expect(attachmentCount == 0)
    }
  }

  @Test
  func commandVPastesPlainTextWhenAttachmentsAreUnavailable() throws {
    let textView = Self.makeTextView()
    textView.canAcceptAttachments = false
    var attachmentCount = 0
    textView.onPasteboardAttachments = { _ in
      attachmentCount += 1
      return true
    }

    try withGeneralPasteboard(data: Data("Ordinary text".utf8), type: .string) {
      let menu = NSMenu(title: "Edit")
      let item = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
      item.target = textView
      menu.addItem(item)
      menu.update()
      #expect(item.isEnabled)
      let event = try #require(Self.pasteEvent(modifiers: .command))
      #expect(menu.performKeyEquivalent(with: event))
      #expect(textView.string == "Ordinary text")
      #expect(attachmentCount == 0)
    }
  }

  @Test
  func controlVPastesAttachmentWhenPasteboardContainsImage() throws {
    let textView = Self.makeTextView()

    var handledPasteboard: NSPasteboard?
    textView.onPasteboardAttachments = { pasteboard in
      handledPasteboard = pasteboard
      return true
    }

    try withGeneralPasteboardImage(type: .png) {
      textView.keyDown(with: try #require(Self.pasteEvent(modifiers: .control)))
    }

    #expect(handledPasteboard === NSPasteboard.general)
  }

  private static func makeTextView() -> ComposerNSTextView {
    let textView = ComposerNSTextView()
    textView.isRichText = false
    textView.importsGraphics = false
    textView.isEditable = true
    textView.canAcceptAttachments = true
    return textView
  }

  private static func pasteEvent(modifiers: NSEvent.ModifierFlags) -> NSEvent? {
    NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: modifiers,
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: modifiers.contains(.control) ? "\u{16}" : "v",
      charactersIgnoringModifiers: "v",
      isARepeat: false,
      keyCode: 9
    )
  }
}

private func withGeneralPasteboardImage(
  type: NSPasteboard.PasteboardType,
  _ body: () throws -> Void
) throws {
  let bitmap = try #require(
    NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )
  )
  for column in 0..<2 {
    for row in 0..<2 {
      bitmap.setColor(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1), atX: column, y: row)
    }
  }
  let data = try #require(
    bitmap.representation(using: type == .tiff ? .tiff : .png, properties: [:]))
  try withGeneralPasteboard(data: data, type: type, body)
}

private func withGeneralPasteboard(
  data: Data,
  type: NSPasteboard.PasteboardType,
  _ body: () throws -> Void
) throws {
  let pasteboard = NSPasteboard.general
  let savedItems = pasteboard.pasteboardItems?.map(ClonePasteboardItem.init) ?? []
  pasteboard.clearContents()
  pasteboard.setData(data, forType: type)

  defer {
    pasteboard.clearContents()
    _ = pasteboard.writeObjects(savedItems.map(\.item))
  }

  try body()
}

private struct ClonePasteboardItem {
  let item: NSPasteboardItem

  init(_ source: NSPasteboardItem) {
    let clone = NSPasteboardItem()
    for type in source.types {
      if let data = source.data(forType: type) {
        clone.setData(data, forType: type)
      }
    }
    item = clone
  }
}
