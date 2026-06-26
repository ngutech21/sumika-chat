import Foundation
import Testing

@testable import Sumika

struct ComposerDraftTextEditorTests {
  @Test
  func insertsIntoEmptyDraft() {
    let insertion = ComposerDraftTextEditor.inserting(
      "hello",
      into: "",
      selectedRange: NSRange(location: 0, length: 0)
    )

    #expect(insertion.text == "hello")
    #expect(insertion.selectedRange.location == 5)
    #expect(insertion.selectedRange.length == 0)
  }

  @Test
  func insertsAtCursorInExistingDraft() {
    let insertion = ComposerDraftTextEditor.inserting(
      "brave ",
      into: "hello world",
      selectedRange: NSRange(location: 6, length: 0)
    )

    #expect(insertion.text == "hello brave world")
    #expect(insertion.selectedRange.location == 12)
    #expect(insertion.selectedRange.length == 0)
  }

  @Test
  func replacesSelectedText() {
    let insertion = ComposerDraftTextEditor.inserting(
      "new",
      into: "replace old text",
      selectedRange: NSRange(location: 8, length: 3)
    )

    #expect(insertion.text == "replace new text")
    #expect(insertion.selectedRange.location == 11)
    #expect(insertion.selectedRange.length == 0)
  }

  @Test
  func clampsOutOfBoundsSelectionToEnd() {
    let insertion = ComposerDraftTextEditor.inserting(
      "!",
      into: "done",
      selectedRange: NSRange(location: 99, length: 8)
    )

    #expect(insertion.text == "done!")
    #expect(insertion.selectedRange.location == 5)
    #expect(insertion.selectedRange.length == 0)
  }

  @Test
  func preservesSlashCommandPrefixWhenInsertedTextKeepsSlashAtStart() {
    let insertion = ComposerDraftTextEditor.inserting(
      "show ",
      into: "/README.md",
      selectedRange: NSRange(location: 1, length: 0)
    )
    let draftState = ComposerDraftState(text: insertion.text)

    #expect(insertion.text == "/show README.md")
    #expect(draftState.slashCommandText == "/show README.md")
  }
}
