import Foundation
import Testing

@testable import LocalCoderCore

struct CurrentPromptContextSelectorTests {
  @Test
  func attachedFileProducesAttachedFileBlock() throws {
    let attachment = ChatAttachment(
      url: URL(filePath: "/tmp/project/Sources/Foo.swift"),
      displayName: "Foo.swift",
      kind: .text,
      content: "let value = 1"
    )
    let workspace = Workspace(
      name: "Project",
      rootURL: URL(filePath: "/tmp/project", directoryHint: .isDirectory)
    )

    let context = CurrentPromptContextSelector().selectContext(
      userInput: "explain this",
      mode: .chat,
      focusedFileState: .empty,
      attachments: [attachment],
      workspace: workspace,
      budget: .focusedFileDefault
    )

    guard case .selected(let selection) = context else {
      Issue.record("Expected selected current prompt context.")
      return
    }
    #expect(selection.truncation == .none)
    #expect(selection.blocks.values.count == 1)
    guard case .attachedFile(let attachedFile) = selection.blocks.values[0] else {
      Issue.record("Expected attached file context block.")
      return
    }
    #expect(attachedFile.path == WorkspaceRelativePath(rawValue: "Sources/Foo.swift"))
    #expect(attachedFile.displayName == "Foo.swift")
    #expect(!attachedFile.contentHash.isEmpty)
    #expect(attachedFile.excerpt?.text == "let value = 1")
    #expect(attachedFile.excerpt?.truncated == false)
    #expect(attachedFile.isEmpty == false)
  }

  @Test
  func attachedFileTakesPrecedenceOverActiveFocusedFile() throws {
    let attachedPath = WorkspaceRelativePath(rawValue: "Attached.swift")
    let focusedPath = WorkspaceRelativePath(rawValue: "Focused.swift")
    let state = FocusedFileState(
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
    let attachment = ChatAttachment(
      url: URL(filePath: "/tmp/Attached.swift"),
      displayName: attachedPath.rawValue,
      kind: .text,
      content: "let attached = true"
    )

    let context = CurrentPromptContextSelector().selectContext(
      userInput: "explain this",
      mode: .inspect,
      focusedFileState: state,
      attachments: [attachment],
      budget: .focusedFileDefault
    )

    guard case .selected(let selection) = context,
      case .attachedFile(let attachedFile) = selection.blocks.values[0]
    else {
      Issue.record("Expected attached file context to take precedence.")
      return
    }
    #expect(attachedFile.path == attachedPath)
    #expect(selection.blocks.values.count == 1)
  }

  @Test
  func multipleAttachmentsProduceBlocksInAttachmentOrder() throws {
    let first = ChatAttachment(
      url: URL(filePath: "/tmp/First.swift"),
      displayName: "First.swift",
      kind: .text,
      content: "first"
    )
    let second = ChatAttachment(
      url: URL(filePath: "/tmp/Second.swift"),
      displayName: "Second.swift",
      kind: .text,
      content: "second"
    )

    let context = CurrentPromptContextSelector().selectContext(
      userInput: "compare",
      mode: .chat,
      focusedFileState: .empty,
      attachments: [first, second],
      budget: .focusedFileDefault
    )

    guard case .selected(let selection) = context else {
      Issue.record("Expected selected current prompt context.")
      return
    }
    #expect(selection.blocks.values.count == 2)
    guard case .attachedFile(let firstContext) = selection.blocks.values[0],
      case .attachedFile(let secondContext) = selection.blocks.values[1]
    else {
      Issue.record("Expected attached file context blocks.")
      return
    }
    #expect(firstContext.path == WorkspaceRelativePath(rawValue: "First.swift"))
    #expect(secondContext.path == WorkspaceRelativePath(rawValue: "Second.swift"))
  }

  @Test
  func attachedFileExcerptIsTruncatedBySharedCharacterBudget() throws {
    let budget = try #require(ContextBudget.checked(maxCharacters: 6))
    let attachment = ChatAttachment(
      url: URL(filePath: "/tmp/Long.swift"),
      displayName: "Long.swift",
      kind: .text,
      content: "0123456789"
    )

    let context = CurrentPromptContextSelector().selectContext(
      userInput: "summarize",
      mode: .inspect,
      focusedFileState: .empty,
      attachments: [attachment],
      budget: budget
    )

    guard case .selected(let selection) = context,
      case .attachedFile(let attachedFile) = selection.blocks.values[0]
    else {
      Issue.record("Expected truncated attached file context block.")
      return
    }
    #expect(selection.truncation == .byCharacterBudget)
    #expect(attachedFile.excerpt?.text == "012345")
    #expect(attachedFile.excerpt?.truncated == true)
  }

  @Test
  func invalidAttachedFileMetadataFallsBackToFocusedFile() throws {
    let focusedPath = WorkspaceRelativePath(rawValue: "Sources/Fallback.swift")
    let state = FocusedFileState(
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
    let invalidAttachment = ChatAttachment(
      url: URL(filePath: "/tmp/Invalid.swift"),
      displayName: "  \n",
      kind: .text,
      content: "let invalid = true"
    )

    let context = CurrentPromptContextSelector().selectContext(
      userInput: "explain fallback",
      mode: .inspect,
      focusedFileState: state,
      attachments: [invalidAttachment],
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
  func rendersAttachedFileContextStably() throws {
    let attachment = ChatAttachment(
      url: URL(filePath: "/tmp/project/Sources/Foo.swift"),
      displayName: "Foo.swift",
      kind: .text,
      content: "let value = 1"
    )
    let workspace = Workspace(
      name: "Project",
      rootURL: URL(filePath: "/tmp/project", directoryHint: .isDirectory)
    )
    let context = CurrentPromptContextSelector().selectContext(
      userInput: "explain",
      mode: .chat,
      focusedFileState: .empty,
      attachments: [attachment],
      workspace: workspace,
      budget: .focusedFileDefault
    )

    let rendered = CurrentPromptContextRenderer.render(context)

    #expect(rendered.count == 1)
    #expect(rendered.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    #expect(rendered[0].contains("Attached file: Sources/Foo.swift"))
    #expect(rendered[0].contains("Display name: Foo.swift"))
    #expect(rendered[0].contains("Content hash:"))
    #expect(rendered[0].contains("Attached content excerpt:"))
    #expect(rendered[0].contains("let value = 1"))
    #expect(rendered[0].contains("Attached context:") == false)
    #expect(rendered[0].contains("File: Foo.swift") == false)
  }

  @Test
  func rendersEmptyAttachedFileWithoutEmptyExcerpt() throws {
    let attachment = ChatAttachment(
      url: URL(filePath: "/tmp/Empty.swift"),
      displayName: "Empty.swift",
      kind: .text,
      content: ""
    )
    let context = CurrentPromptContextSelector().selectContext(
      userInput: "explain",
      mode: .chat,
      focusedFileState: .empty,
      attachments: [attachment],
      budget: .focusedFileDefault
    )

    let rendered = CurrentPromptContextRenderer.render(context)

    #expect(rendered.count == 1)
    #expect(rendered[0].contains("Attached file: Empty.swift"))
    #expect(rendered[0].contains("Attached content excerpt:") == false)
    #expect(rendered[0].contains("Attached file is empty."))
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
