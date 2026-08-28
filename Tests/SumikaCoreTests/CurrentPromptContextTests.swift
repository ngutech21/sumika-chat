import Foundation
import Testing

@testable import SumikaCore

struct CurrentPromptContextSelectorTests {
  @Test
  func attachedFileProducesAttachedFileBlock() throws {
    let attachment = makeTextChatAttachment(
      displayName: "Foo.swift",
      content: "let value = 1"
    )
    let context = CurrentPromptContextSelector().selectContext(
      mode: .chat,
      focusedFileState: .empty,
      attachments: [attachment],
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
    #expect(attachedFile.attachmentID == attachment.id)
    #expect(attachedFile.displayName == "Foo.swift")
    #expect(!attachedFile.contentHash.isEmpty)
    #expect(attachedFile.excerpt?.text == "let value = 1")
    #expect(attachedFile.excerpt?.truncated == false)
    #expect(attachedFile.isEmpty == false)
  }

  @Test
  func attachedFileTakesPrecedenceOverActiveFocusedFile() throws {
    let focusedPath = WorkspaceRelativePath(rawValue: "Focused.swift")
    let state = FocusedFileState(
      activePath: focusedPath,
      recentPaths: [
        FocusedPath(path: focusedPath, source: .readFile, confidence: .active)
      ],
      snapshots: [
        focusedPath: FocusedFileSnapshot(
          contentHash: "hash",
          excerpt: "let focused = true",
          fullContentAvailable: true
        )
      ]
    )
    let attachment = makeTextChatAttachment(
      displayName: "Attached.swift",
      content: "let attached = true"
    )

    let context = CurrentPromptContextSelector().selectContext(
      mode: .agent,
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
    #expect(attachedFile.attachmentID == attachment.id)
    #expect(attachedFile.displayName == "Attached.swift")
    #expect(selection.blocks.values.count == 1)
  }

  @Test
  func multipleAttachmentsProduceBlocksInAttachmentOrder() throws {
    let first = makeTextChatAttachment(
      displayName: "First.swift",
      content: "first"
    )
    let second = makeTextChatAttachment(
      displayName: "Second.swift",
      content: "second"
    )

    let context = CurrentPromptContextSelector().selectContext(
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
    #expect(firstContext.attachmentID == first.id)
    #expect(secondContext.attachmentID == second.id)
  }

  @Test
  func attachedFileExcerptIsTruncatedBySharedCharacterBudget() throws {
    let budget = try #require(ContextBudget.checked(maxCharacters: 6))
    let attachment = makeTextChatAttachment(
      displayName: "Long.swift",
      content: "0123456789"
    )

    let context = CurrentPromptContextSelector().selectContext(
      mode: .agent,
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
          contentHash: "hash",
          excerpt: "let fallback = true",
          fullContentAvailable: true
        )
      ]
    )
    let invalidAttachment = makeTextChatAttachment(
      displayName: "  \n",
      content: "let invalid = true"
    )

    let context = CurrentPromptContextSelector().selectContext(
      mode: .agent,
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
          contentHash: "hash",
          excerpt: "<h1>Hello</h1>",
          fullContentAvailable: true
        )
      ]
    )

    let context = CurrentPromptContextSelector().selectContext(
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
    #expect(focusedFile.fullContentAvailable == true)
    #expect(focusedFile.isReuseEligible == false)
  }

  @Test
  func onlyCompleteReadFileContextIsReuseEligible() throws {
    let path = WorkspaceRelativePath(rawValue: "Sources/App.swift")
    let state = FocusedFileState(
      activePath: path,
      recentPaths: [
        FocusedPath(path: path, source: .readFile, confidence: .active)
      ],
      snapshots: [
        path: FocusedFileSnapshot(
          contentHash: "hash",
          excerpt: "let value = 1",
          fullContentAvailable: true
        )
      ]
    )

    let context = CurrentPromptContextSelector().selectContext(
      mode: .agent,
      focusedFileState: state,
      budget: .focusedFileDefault
    )

    guard case .selected(let selection) = context,
      case .focusedFile(let focusedFile) = selection.blocks.values[0]
    else {
      Issue.record("Expected focused file context block.")
      return
    }
    #expect(focusedFile.fullContentAvailable == true)
    #expect(focusedFile.isReuseEligible == true)
  }

  @Test
  func completeEmptyReadFileContextIsReuseEligibleAndExplicitlyRendered() throws {
    let path = WorkspaceRelativePath(rawValue: "Sources/Empty.swift")
    let state = FocusedFileState(
      activePath: path,
      recentPaths: [
        FocusedPath(path: path, source: .readFile, confidence: .active)
      ],
      snapshots: [
        path: FocusedFileSnapshot(
          contentHash: "empty-hash",
          excerpt: nil,
          fullContentAvailable: true
        )
      ]
    )

    let context = CurrentPromptContextSelector().selectContext(
      mode: .agent,
      focusedFileState: state,
      budget: .focusedFileDefault
    )
    guard case .selected(let selection) = context,
      case .focusedFile(let focusedFile) = selection.blocks.values[0]
    else {
      Issue.record("Expected focused file context block.")
      return
    }

    #expect(focusedFile.excerpt?.text == "")
    #expect(focusedFile.isReuseEligible)
    #expect(
      CurrentPromptContextRenderer.renderSupportingContext(context)[0].contains("(empty file)"))
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
          contentHash: "hash",
          excerpt: "0123456789",
          fullContentAvailable: true
        )
      ]
    )

    let context = CurrentPromptContextSelector().selectContext(
      mode: .agent,
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
    #expect(focusedFile.fullContentAvailable == true)
    #expect(focusedFile.isReuseEligible == false)
  }

  @Test
  func legacyAttachmentPathsAreNotPresentedAsAmbiguousWorkspaceFiles() throws {
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
      mode: .chat,
      focusedFileState: state,
      budget: .focusedFileDefault
    )

    #expect(context == .empty(.focusedFileDefault))
  }

  @Test
  func emptyFocusedStateProducesEmptyContext() {
    let context = CurrentPromptContextSelector().selectContext(
      mode: .chat,
      focusedFileState: .empty,
      budget: .focusedFileDefault
    )

    #expect(context == .empty(.focusedFileDefault))
  }
}

struct CurrentPromptContextRendererTests {
  @Test
  func rendersCompleteDOCXMarkdownAsNonWorkspaceAttachment() throws {
    let attachment = makeTextChatAttachment(
      displayName: "report.docx",
      content: "let value = 1"
    )
    let context = CurrentPromptContextSelector().selectContext(
      mode: .chat,
      focusedFileState: .empty,
      attachments: [attachment],
      budget: .focusedFileDefault
    )

    let rendered = CurrentPromptContextRenderer.renderSupportingContext(context)

    #expect(rendered.count == 1)
    #expect(rendered.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    #expect(rendered[0].contains("Chat attachment: report.docx"))
    #expect(rendered[0].contains("Content hash:"))
    #expect(rendered[0].contains("Complete DOCX-derived Markdown:"))
    #expect(rendered[0].contains("let value = 1"))
    #expect(rendered[0].contains("not a workspace path"))
    #expect(rendered[0].contains("Attached file:") == false)
    #expect(rendered[0].contains("Attached content excerpt:") == false)
    #expect(
      rendered[0]
        == """
        Chat attachment: report.docx
        Source: chat attachment, not a workspace path.
        Content hash: 5eefe8717fb3aae43f2029837446312dd248d2d3564cd48adebc866067bf03e7
        Complete DOCX-derived Markdown:
        let value = 1
        Use this content directly. Do not call workspace file/search tools (read_file, show_file, list_files, glob_files, or search_files) for this attachment.
        """)
  }

  @Test
  func attachedFileContextRendersAndRetainsTypedSnapshot() throws {
    let attachment = makeTextChatAttachment(
      displayName: "Foo.swift",
      content: "let value = 1"
    )
    let context = CurrentPromptContextSelector().selectContext(
      mode: .chat,
      focusedFileState: .empty,
      attachments: [attachment],
      budget: .focusedFileDefault
    )

    let rendered = CurrentPromptContextRenderer.renderSupportingContext(context)

    #expect(rendered.count == 1)
    guard case .selected(let selection) = context,
      case .attachedFile(let attachedFile) = selection.blocks.values[0]
    else {
      Issue.record("Expected typed attached file context.")
      return
    }
    #expect(selection.budget.maxCharacters == ContextBudget.focusedFileDefault.maxCharacters)
    #expect(selection.truncation == .none)
    #expect(attachedFile.attachmentID == attachment.id)
    #expect(attachedFile.displayName == "Foo.swift")
    #expect(!attachedFile.contentHash.isEmpty)
    #expect(attachedFile.excerpt?.text == "let value = 1")
    #expect(attachedFile.excerpt?.truncated == false)
    #expect(attachedFile.isEmpty == false)
  }

  @Test
  func rendersEmptyAttachedFileWithoutEmptyExcerpt() throws {
    let attachment = makeTextChatAttachment(
      displayName: "Empty.swift",
      content: ""
    )
    let context = CurrentPromptContextSelector().selectContext(
      mode: .chat,
      focusedFileState: .empty,
      attachments: [attachment],
      budget: .focusedFileDefault
    )

    let rendered = CurrentPromptContextRenderer.renderSupportingContext(context)

    #expect(rendered.count == 1)
    #expect(rendered[0].contains("Chat attachment: Empty.swift"))
    #expect(rendered[0].contains("Complete attached text:") == false)
    #expect(rendered[0].contains("Attached content is empty."))
    #expect(rendered[0].contains("Do not call workspace file/search tools"))
  }

  @Test
  func rendersTruncatedDOCXMarkdownAsIncompleteAndNonRetrievableByWorkspaceTools() throws {
    let budget = try #require(ContextBudget.checked(maxCharacters: 6))
    let attachment = makeTextChatAttachment(
      displayName: "report.docx",
      content: "0123456789"
    )
    let context = CurrentPromptContextSelector().selectContext(
      mode: .agent,
      focusedFileState: .empty,
      attachments: [attachment],
      budget: budget
    )

    let rendered = CurrentPromptContextRenderer.renderSupportingContext(context)

    #expect(rendered.count == 1)
    #expect(rendered[0].contains("DOCX-derived Markdown excerpt (incomplete):"))
    #expect(rendered[0].contains("Complete DOCX-derived Markdown:") == false)
    #expect(rendered[0].contains("012345"))
    #expect(rendered[0].contains("Workspace file/search tools cannot retrieve the rest."))
    #expect(rendered[0].contains("Do not call read_file"))
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
          contentHash: "hash",
          excerpt: "<h1>Hello</h1>",
          fullContentAvailable: true
        )
      ]
    )
    let context = CurrentPromptContextSelector().selectContext(
      mode: .chat,
      focusedFileState: state,
      budget: .focusedFileDefault
    )

    let rendered = CurrentPromptContextRenderer.renderSupportingContext(context)

    #expect(rendered.count == 1)
    #expect(rendered.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    #expect(rendered[0].contains("Current focused file: index.html"))
    #expect(rendered[0].contains("Source: previous write_file"))
    #expect(rendered[0].contains("Content hash:") == false)
    #expect(rendered[0].contains("Known content excerpt:"))
    #expect(rendered[0].contains("<h1>Hello</h1>"))
    #expect(
      rendered[0].contains("Explicit file paths in the user request or tool call take precedence."))
  }

  @Test
  func rendersEligibleFocusedFileAsCompactReuseWhenRequested() throws {
    let path = WorkspaceRelativePath(rawValue: "Sources/App.swift")
    let state = FocusedFileState(
      activePath: path,
      recentPaths: [
        FocusedPath(path: path, source: .readFile, confidence: .active)
      ],
      snapshots: [
        path: FocusedFileSnapshot(
          contentHash: "hash",
          excerpt: "let value = 1",
          fullContentAvailable: true
        )
      ]
    )
    let context = CurrentPromptContextSelector().selectContext(
      mode: .agent,
      focusedFileState: state,
      budget: .focusedFileDefault
    )

    let rendered = CurrentPromptContextRenderer.renderSupportingContext(
      context,
      focusedFilePresentation: .compactReuse
    )

    #expect(
      rendered
        == [
          """
          Current focused file: Sources/App.swift
          Source: previous read_file
          Same known complete snapshot as in the recent context; content is not repeated.
          Call read_file before editing if the file may have changed.
          """
        ])
  }

  @Test
  func compactReuseRequestFallsBackToFullRenderingForNonReadFileSources() throws {
    let path = WorkspaceRelativePath(rawValue: "Sources/App.swift")
    for source in [FocusedPathSource.writeFile, .editFile] {
      let state = FocusedFileState(
        activePath: path,
        recentPaths: [
          FocusedPath(path: path, source: source, confidence: .active)
        ],
        snapshots: [
          path: FocusedFileSnapshot(
            contentHash: "hash",
            excerpt: "let value = 1",
            fullContentAvailable: true
          )
        ]
      )
      let context = CurrentPromptContextSelector().selectContext(
        mode: .agent,
        focusedFileState: state,
        budget: .focusedFileDefault
      )

      let rendered = CurrentPromptContextRenderer.renderSupportingContext(
        context,
        focusedFilePresentation: .compactReuse
      )

      #expect(rendered[0].contains("Known content excerpt:"))
      #expect(rendered[0].contains("Same known complete snapshot") == false)
    }
  }

  @Test
  func rendersLegacyFocusedAttachmentWithoutWorkspacePathInstructions() throws {
    let path = WorkspaceRelativePath(rawValue: "report.docx")
    let state = FocusedFileState(
      activePath: path,
      recentPaths: [
        FocusedPath(
          path: path,
          source: .attachment,
          confidence: .active
        )
      ],
      snapshots: [
        path: FocusedFileSnapshot(
          contentHash: "hash",
          excerpt: "# Converted document",
          fullContentAvailable: true
        )
      ]
    )
    let context = CurrentPromptContextSelector().selectContext(
      mode: .chat,
      focusedFileState: state,
      budget: .focusedFileDefault
    )

    let rendered = CurrentPromptContextRenderer.renderSupportingContext(context)

    #expect(rendered.count == 1)
    #expect(rendered[0].contains("Legacy chat attachment: report.docx"))
    #expect(rendered[0].contains("not a workspace path"))
    #expect(rendered[0].contains("Complete known attachment content:"))
    #expect(rendered[0].contains("# Converted document"))
    #expect(rendered[0].contains("Do not call workspace file/search tools"))
    #expect(rendered[0].contains("Current focused file:") == false)
  }

  @Test
  func rendersEmptyContextAndRetainsTypedBudget() {
    let context = CurrentPromptContext.empty(.focusedFileDefault)
    let rendered = CurrentPromptContextRenderer.renderSupportingContext(context)

    #expect(rendered.isEmpty)
    guard case .empty(let budget) = context else {
      Issue.record("Expected typed empty context.")
      return
    }
    #expect(budget.maxCharacters == ContextBudget.focusedFileDefault.maxCharacters)
  }
}
