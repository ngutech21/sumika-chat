import Foundation
import SumikaCore
import Testing

@testable import SumikaApp

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

  @Test
  func findsSkillTokenAtCursorBoundaryAndUsesUTF16Range() throws {
    let text = "😀 Use $rev then continue"
    let nsText = text as NSString
    let tokenRange = nsText.range(of: "$rev")
    let state = ComposerDraftState(
      text: text,
      selectedRange: NSRange(
        location: tokenRange.location + tokenRange.length,
        length: 0
      )
    )

    let token = try #require(state.skillSuggestionToken)
    #expect(token.prefix == "rev")
    #expect(token.range == tokenRange)
  }

  @Test
  func ignoresDollarWithoutTokenBoundary() {
    let text = "price$rev"
    let state = ComposerDraftState(text: text)

    #expect(state.skillSuggestionToken == nil)
  }

  @Test
  func skillMentionBindingsShiftBeforeEditsAndDropOverlappingEdits() {
    let id = SkillID(scope: .project, name: "review")
    let mention = SkillMention(id: id, range: NSRange(location: 4, length: 7))

    let shifted = ComposerSkillMentionEditor.updating(
      [mention],
      replacing: NSRange(location: 0, length: 0),
      with: "Go "
    )
    let removed = ComposerSkillMentionEditor.updating(
      shifted,
      replacing: NSRange(location: 9, length: 1),
      with: "x"
    )

    #expect(shifted == [SkillMention(id: id, range: NSRange(location: 7, length: 7))])
    #expect(removed.isEmpty)
  }

  @Test
  func skillMentionBindingsDropWhenAdjacentEditsBreakTokenBoundaries() {
    let id = SkillID(scope: .project, name: "review")
    let mention = SkillMention(id: id, range: NSRange(location: 4, length: 7))
    let leadingEdit = ComposerSkillMentionEditor.updating(
      [mention],
      replacing: NSRange(location: 4, length: 0),
      with: "x"
    )
    let trailingEdit = ComposerSkillMentionEditor.updating(
      [mention],
      replacing: NSRange(location: 11, length: 0),
      with: "x"
    )

    #expect(
      ComposerSkillMentionEditor.validMentions(leadingEdit, in: "Use x$review").isEmpty
    )
    #expect(
      ComposerSkillMentionEditor.validMentions(trailingEdit, in: "Use $reviewx").isEmpty
    )
    #expect(
      ComposerSkillMentionEditor.validMentions([mention], in: "Use $review.") == [mention]
    )
  }
}
