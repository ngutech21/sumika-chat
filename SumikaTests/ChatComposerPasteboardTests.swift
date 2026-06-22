import AppKit
import Testing

@testable import Sumika

@MainActor
@Suite(.serialized)
struct ChatComposerPasteboardTests {
  @Test
  func controlVPastesAttachmentWhenPasteboardContainsImage() throws {
    let textView = ComposerNSTextView()
    textView.canAcceptAttachments = true

    var handledPasteboard: NSPasteboard?
    textView.onPasteboardAttachments = { pasteboard in
      handledPasteboard = pasteboard
      return true
    }

    try withGeneralPasteboardPNG {
      textView.keyDown(with: try #require(Self.controlVEvent()))
    }

    #expect(handledPasteboard === NSPasteboard.general)
  }

  private static func controlVEvent() -> NSEvent? {
    NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: [.control],
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: "\u{16}",
      charactersIgnoringModifiers: "v",
      isARepeat: false,
      keyCode: 9
    )
  }
}

private func withGeneralPasteboardPNG(_ body: () throws -> Void) throws {
  let pasteboard = NSPasteboard.general
  let savedItems = pasteboard.pasteboardItems?.map(ClonePasteboardItem.init) ?? []
  pasteboard.clearContents()
  pasteboard.setData(Data("png".utf8), forType: .png)

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
