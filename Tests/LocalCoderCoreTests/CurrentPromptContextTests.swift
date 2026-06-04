import Foundation
import Testing

@testable import LocalCoderCore

struct CurrentPromptContextSelectorTests {
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

    let context = CurrentPromptContextSelector().selectContext(
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

    let context = CurrentPromptContextSelector().selectContext(
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

    let context = CurrentPromptContextSelector().selectContext(
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
    let context = CurrentPromptContextSelector().selectContext(
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
    let context = CurrentPromptContextSelector().selectContext(
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
    let context = CurrentPromptContextSelector().selectContext(
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
