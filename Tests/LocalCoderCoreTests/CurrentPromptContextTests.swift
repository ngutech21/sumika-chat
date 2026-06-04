import Foundation
import Testing

@testable import LocalCoderCore

struct FocusedPromptContextSelectorTests {
  @Test
  func activeFileProducesFocusedFileBlock() throws {
    let path = WorkspaceRelativePath(rawValue: "index.html")
    let state = FocusedFileState(
      activePath: path,
      recentPaths: [
        FocusedPath(
          path: path,
          source: .writeFile,
          confidence: .active,
          updatedAt: Date(timeIntervalSinceReferenceDate: 1)
        )
      ],
      snapshots: [
        path: FocusedFileSnapshot(
          path: path,
          contentHash: "hash",
          excerpt: "<h1>Hello</h1>",
          fullContentAvailable: true
        )
      ]
    )

    let context = FocusedPromptContextSelector().selectContext(
      userInput: "what changed?",
      mode: .chat,
      focusedFileState: state,
      budget: .focusedFileDefault
    )

    guard case .selected(let selection) = context else {
      Issue.record("Expected selected current prompt context.")
      return
    }
    #expect(selection.truncation == .none)
    #expect(selection.blocks.values.count == 1)
    guard case .focusedFile(let focusedFile) = selection.blocks.values[0] else {
      Issue.record("Expected focused file context block.")
      return
    }
    #expect(focusedFile.path == path)
    #expect(focusedFile.source == .writeFile)
    #expect(focusedFile.contentHash == "hash")
    #expect(focusedFile.excerpt?.text == "<h1>Hello</h1>")
    #expect(focusedFile.excerpt?.truncated == false)
  }

  @Test
  func selectedRangeTakesPrecedenceOverActiveFocusedFile() throws {
    let selectedPath = WorkspaceRelativePath(rawValue: "Sources/Selected.swift")
    let focusedPath = WorkspaceRelativePath(rawValue: "Sources/Focused.swift")
    let displayState = try #require(
      WorkspaceDisplayState.withSelectedRange(
        path: selectedPath,
        startLine: 3,
        endLine: 5,
        text: "let selected = true"
      ))
    let focusedState = FocusedFileState(
      activePath: focusedPath,
      recentPaths: [
        FocusedPath(path: focusedPath, source: .readFile, confidence: .active)
      ],
      snapshots: [
        focusedPath: FocusedFileSnapshot(
          path: focusedPath,
          contentHash: "hash",
          excerpt: "let focused = true",
          fullContentAvailable: true
        )
      ]
    )

    let context = CurrentPromptContextSelector().selectContext(
      userInput: "explain this",
      mode: .inspect,
      focusedFileState: focusedState,
      workspaceDisplayState: displayState,
      budget: .focusedFileDefault
    )

    guard case .selected(let selection) = context else {
      Issue.record("Expected selected current prompt context.")
      return
    }
    guard case .selectedRange(let selectedRange) = selection.blocks.values[0] else {
      Issue.record("Expected selected range to take precedence.")
      return
    }
    #expect(selection.truncation == .none)
    #expect(selectedRange.range.path == selectedPath)
    #expect(selectedRange.range.lineRange.startLine == 3)
    #expect(selectedRange.range.lineRange.endLine == 5)
    #expect(selectedRange.range.excerpt?.text == "let selected = true")
  }

  @Test
  func visibleRangeIsUsedWhenSelectedRangeIsMissing() throws {
    let path = WorkspaceRelativePath(rawValue: "Sources/Visible.swift")
    let displayState = try #require(
      WorkspaceDisplayState.withVisibleRange(
        path: path,
        startLine: 10,
        endLine: 12,
        text: "func visible() {}"
      ))

    let context = CurrentPromptContextSelector().selectContext(
      userInput: "what is visible?",
      mode: .chat,
      focusedFileState: .empty,
      workspaceDisplayState: displayState,
      budget: .focusedFileDefault
    )

    guard case .selected(let selection) = context,
      case .visibleRange(let visibleRange) = selection.blocks.values[0]
    else {
      Issue.record("Expected visible range context block.")
      return
    }
    #expect(selection.truncation == .none)
    #expect(visibleRange.range.path == path)
    #expect(visibleRange.range.lineRange.startLine == 10)
    #expect(visibleRange.range.lineRange.endLine == 12)
    #expect(visibleRange.range.excerpt?.text == "func visible() {}")
  }

  @Test
  func emptyRangeTextIsRejectedAndFallsBackToFocusedFile() throws {
    let path = WorkspaceRelativePath(rawValue: "Sources/Fallback.swift")
    let invalidDisplayState = WorkspaceDisplayState.withSelectedRange(
      path: path,
      startLine: 1,
      endLine: 1,
      text: "  \n"
    )
    let focusedState = FocusedFileState(
      activePath: path,
      recentPaths: [
        FocusedPath(path: path, source: .readFile, confidence: .active)
      ],
      snapshots: [
        path: FocusedFileSnapshot(
          path: path,
          contentHash: "hash",
          excerpt: "let fallback = true",
          fullContentAvailable: true
        )
      ]
    )

    #expect(invalidDisplayState == nil)
    let context = CurrentPromptContextSelector().selectContext(
      userInput: "explain fallback",
      mode: .inspect,
      focusedFileState: focusedState,
      workspaceDisplayState: invalidDisplayState ?? .empty,
      budget: .focusedFileDefault
    )

    guard case .selected(let selection) = context,
      case .focusedFile(let focusedFile) = selection.blocks.values[0]
    else {
      Issue.record("Expected focused file fallback.")
      return
    }
    #expect(focusedFile.path == path)
    #expect(focusedFile.excerpt?.text == "let fallback = true")
  }

  @Test
  func emptyRangePathIsRejectedAndFallsBackToFocusedFile() throws {
    let focusedPath = WorkspaceRelativePath(rawValue: "Sources/Fallback.swift")
    let invalidDisplayState = WorkspaceDisplayState.withSelectedRange(
      path: WorkspaceRelativePath(rawValue: " \n"),
      startLine: 1,
      endLine: 1,
      text: "let selected = true"
    )
    let focusedState = FocusedFileState(
      activePath: focusedPath,
      recentPaths: [
        FocusedPath(path: focusedPath, source: .readFile, confidence: .active)
      ],
      snapshots: [
        focusedPath: FocusedFileSnapshot(
          path: focusedPath,
          contentHash: "hash",
          excerpt: "let fallback = true",
          fullContentAvailable: true
        )
      ]
    )

    #expect(invalidDisplayState == nil)
    let context = CurrentPromptContextSelector().selectContext(
      userInput: "explain fallback",
      mode: .inspect,
      focusedFileState: focusedState,
      workspaceDisplayState: invalidDisplayState ?? .empty,
      budget: .focusedFileDefault
    )

    guard case .selected(let selection) = context,
      case .focusedFile(let focusedFile) = selection.blocks.values[0]
    else {
      Issue.record("Expected focused file fallback.")
      return
    }
    #expect(focusedFile.path == focusedPath)
  }

  @Test
  func rangeExcerptIsTruncatedByCharacterBudget() throws {
    let path = WorkspaceRelativePath(rawValue: "Sources/LongSelection.swift")
    let budget = try #require(ContextBudget.checked(maxCharacters: 6))
    let displayState = try #require(
      WorkspaceDisplayState.withSelectedRange(
        path: path,
        startLine: 2,
        endLine: 4,
        text: "0123456789"
      ))

    let context = CurrentPromptContextSelector().selectContext(
      userInput: "summarize selection",
      mode: .inspect,
      focusedFileState: .empty,
      workspaceDisplayState: displayState,
      budget: budget
    )

    guard case .selected(let selection) = context,
      case .selectedRange(let selectedRange) = selection.blocks.values[0]
    else {
      Issue.record("Expected truncated selected range context block.")
      return
    }
    #expect(selection.truncation == .byCharacterBudget)
    #expect(selectedRange.range.excerpt?.text == "012345")
    #expect(selectedRange.range.excerpt?.truncated == true)
  }

  @Test
  func longExcerptIsTruncatedByCharacterBudget() throws {
    let path = WorkspaceRelativePath(rawValue: "Sources/Foo.swift")
    let budget = try #require(ContextBudget.checked(maxCharacters: 5))
    let state = FocusedFileState(
      activePath: path,
      recentPaths: [
        FocusedPath(path: path, source: .readFile, confidence: .active)
      ],
      snapshots: [
        path: FocusedFileSnapshot(
          path: path,
          contentHash: "hash",
          excerpt: "0123456789",
          fullContentAvailable: false
        )
      ]
    )

    let context = FocusedPromptContextSelector().selectContext(
      userInput: "summarize",
      mode: .inspect,
      focusedFileState: state,
      budget: budget
    )

    guard case .selected(let selection) = context,
      case .focusedFile(let focusedFile) = selection.blocks.values[0]
    else {
      Issue.record("Expected truncated focused file context block.")
      return
    }
    #expect(selection.truncation == .byCharacterBudget)
    #expect(focusedFile.excerpt?.text == "01234")
    #expect(focusedFile.excerpt?.truncated == true)
  }

  @Test
  func ambiguousRecentFilesProduceAmbiguousRecentFilesBlock() throws {
    let firstPath = WorkspaceRelativePath(rawValue: "index.html")
    let secondPath = WorkspaceRelativePath(rawValue: "style.css")
    let state = FocusedFileState(
      activePath: nil,
      recentPaths: [
        FocusedPath(path: firstPath, source: .attachment, confidence: .ambiguous),
        FocusedPath(path: secondPath, source: .attachment, confidence: .ambiguous),
      ]
    )

    let context = FocusedPromptContextSelector().selectContext(
      userInput: "which file?",
      mode: .chat,
      focusedFileState: state,
      budget: .focusedFileDefault
    )

    guard case .selected(let selection) = context,
      case .ambiguousRecentFiles(let ambiguousFiles) = selection.blocks.values[0]
    else {
      Issue.record("Expected ambiguous recent files context block.")
      return
    }
    #expect(selection.truncation == .none)
    #expect(ambiguousFiles.paths.values == [firstPath, secondPath])
  }

  @Test
  func emptyFocusedStateProducesEmptyContext() {
    let context = FocusedPromptContextSelector().selectContext(
      userInput: "hello",
      mode: .chat,
      focusedFileState: .empty,
      budget: .focusedFileDefault
    )

    #expect(context == .empty(.focusedFileDefault))
  }
}

struct CurrentPromptContextRendererTests {
  @Test
  func rendersSelectedAndVisibleRangesStably() throws {
    let selectedState = try #require(
      WorkspaceDisplayState.withSelectedRange(
        path: WorkspaceRelativePath(rawValue: "Sources/Selected.swift"),
        startLine: 4,
        endLine: 6,
        text: "let value = selected"
      ))
    let visibleState = try #require(
      WorkspaceDisplayState.withVisibleRange(
        path: WorkspaceRelativePath(rawValue: "Sources/Visible.swift"),
        startLine: 8,
        endLine: 8,
        text: "let value = visible"
      ))
    let selectedContext = CurrentPromptContextSelector().selectContext(
      userInput: "explain",
      mode: .chat,
      focusedFileState: .empty,
      workspaceDisplayState: selectedState,
      budget: .focusedFileDefault
    )
    let visibleContext = CurrentPromptContextSelector().selectContext(
      userInput: "explain",
      mode: .chat,
      focusedFileState: .empty,
      workspaceDisplayState: visibleState,
      budget: .focusedFileDefault
    )

    let selectedRendered = CurrentPromptContextRenderer.render(selectedContext)
    let visibleRendered = CurrentPromptContextRenderer.render(visibleContext)

    #expect(selectedRendered.count == 1)
    #expect(visibleRendered.count == 1)
    #expect(
      selectedRendered.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    #expect(
      visibleRendered.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    #expect(selectedRendered[0].contains("Selected file range: Sources/Selected.swift"))
    #expect(selectedRendered[0].contains("Lines: 4-6"))
    #expect(selectedRendered[0].contains("Selected content excerpt:"))
    #expect(selectedRendered[0].contains("let value = selected"))
    #expect(visibleRendered[0].contains("Visible file range: Sources/Visible.swift"))
    #expect(visibleRendered[0].contains("Lines: 8"))
    #expect(visibleRendered[0].contains("Visible content excerpt:"))
    #expect(visibleRendered[0].contains("let value = visible"))
  }

  @Test
  func rendersFocusedFileContextStably() throws {
    let path = WorkspaceRelativePath(rawValue: "index.html")
    let state = FocusedFileState(
      activePath: path,
      recentPaths: [
        FocusedPath(path: path, source: .writeFile, confidence: .active)
      ],
      snapshots: [
        path: FocusedFileSnapshot(
          path: path,
          contentHash: "hash",
          excerpt: "<h1>Hello</h1>",
          fullContentAvailable: true
        )
      ]
    )
    let context = FocusedPromptContextSelector().selectContext(
      userInput: "what is this?",
      mode: .chat,
      focusedFileState: state,
      budget: .focusedFileDefault
    )

    let rendered = CurrentPromptContextRenderer.render(context)

    #expect(rendered.count == 1)
    #expect(rendered.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    #expect(rendered[0].contains("Current focused file: index.html"))
    #expect(rendered[0].contains("Source: previous write_file"))
    #expect(rendered[0].contains("Content hash: hash"))
    #expect(rendered[0].contains("Known content excerpt:"))
    #expect(rendered[0].contains("<h1>Hello</h1>"))
    #expect(
      rendered[0].contains("Explicit file paths in the user request or tool call take precedence."))
  }

  @Test
  func rendersAmbiguousRecentFilesWithoutClaimingActiveFile() throws {
    let state = FocusedFileState(
      activePath: nil,
      recentPaths: [
        FocusedPath(
          path: WorkspaceRelativePath(rawValue: "index.html"),
          source: .attachment,
          confidence: .ambiguous
        ),
        FocusedPath(
          path: WorkspaceRelativePath(rawValue: "style.css"),
          source: .attachment,
          confidence: .ambiguous
        ),
      ]
    )
    let context = FocusedPromptContextSelector().selectContext(
      userInput: "help",
      mode: .chat,
      focusedFileState: state,
      budget: .focusedFileDefault
    )

    let rendered = CurrentPromptContextRenderer.render(context)

    #expect(rendered.count == 1)
    #expect(rendered[0].contains("Recent files are ambiguous:"))
    #expect(rendered[0].contains("Current focused file:") == false)
    #expect(rendered[0].contains("- index.html"))
    #expect(rendered[0].contains("- style.css"))
  }
}
