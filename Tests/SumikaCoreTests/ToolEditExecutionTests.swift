import Foundation
import SumikaTestSupport
import Testing

@testable import SumikaCore

@Suite(TemporaryDirectoryTrait(named: "sumika-tool-edit-tests"))
struct ToolEditExecutionTests {
  @Test
  func sameFileEditGroupPreviewsAndCommitsOneCombinedTransaction() async throws {
    let workspace = try makeWorkspace()
    try write("one\ntwo\nthree\nfour\n", to: "notes.txt", in: workspace)
    let orchestrator = ToolOrchestrator(executorRegistry: .codingAgent)
    let requests = [
      request(
        .editFile,
        workspace: workspace,
        arguments: editArguments(path: "notes.txt", oldText: "one", newText: "ONE")
      ),
      request(
        .editFile,
        workspace: workspace,
        arguments: editArguments(path: "./notes.txt", oldText: "four", newText: "FOUR")
      ),
    ]

    let pending = await orchestrator.prepareSameFileEditGroup(
      requests: requests,
      workspace: workspace
    )

    #expect(pending.map(\.status) == [.awaitingApproval, .awaitingApproval])
    #expect(pending[0].approvalPreview?.affectedPaths == ["notes.txt"])
    #expect(pending[0].approvalPreview?.text.contains("-one") == true)
    #expect(pending[0].approvalPreview?.text.contains("+ONE") == true)
    #expect(pending[0].approvalPreview?.text.contains("-four") == true)
    #expect(pending[0].approvalPreview?.text.contains("+FOUR") == true)
    #expect(pending[0].approvalPreview?.text.components(separatedBy: "@@").count == 5)
    #expect(pending[1].approvalPreview == nil)
    #expect(
      try String(contentsOf: workspace.rootURL.appending(path: "notes.txt"), encoding: .utf8)
        == "one\ntwo\nthree\nfour\n")

    let completed = await orchestrator.executeApprovedSameFileEditGroup(
      records: pending,
      enforceApprovedScope: true,
      workspace: workspace
    )

    #expect(completed.map(\.id) == pending.map(\.id))
    #expect(completed.map(\.status) == [.completed, .completed])
    #expect(
      completed.allSatisfy { record in
        guard case .editFile(.success) = record.resultPayload else {
          return false
        }
        return true
      })
    #expect(
      try String(contentsOf: workspace.rootURL.appending(path: "notes.txt"), encoding: .utf8)
        == "ONE\ntwo\nthree\nFOUR\n")
  }

  @Test
  func sameFileEditGroupUsesTheRegisteredExecutorConfiguration() async throws {
    let workspace = try makeWorkspace()
    try write("one\ntwo\n", to: "notes.txt", in: workspace)
    let registry = ToolExecutorRegistry([
      AnyToolExecutor(
        EditFileToolExecutor(
          receiptPolicy: AppliedEditReceiptPolicy(maxChangedLines: 1, maxBytes: 1_024)
        ))
    ])
    let orchestrator = ToolOrchestrator(executorRegistry: registry)
    let pending = await orchestrator.prepareSameFileEditGroup(
      requests: [
        request(
          .editFile,
          workspace: workspace,
          arguments: editArguments(path: "notes.txt", oldText: "one", newText: "ONE")
        ),
        request(
          .editFile,
          workspace: workspace,
          arguments: editArguments(path: "notes.txt", oldText: "two", newText: "TWO")
        ),
      ],
      workspace: workspace
    )

    let completed = await orchestrator.executeApprovedSameFileEditGroup(
      records: pending,
      enforceApprovedScope: true,
      workspace: workspace
    )

    let receipts = completed.compactMap { record -> AppliedEditReceipt? in
      guard case .editFile(.success(let receipt)) = record.resultPayload else {
        return nil
      }
      return receipt
    }
    #expect(receipts.count == 2)
    #expect(receipts.allSatisfy { $0.diff.truncated })
  }

  @Test
  func sameFileEditGroupOffsetsLaterReceiptsAfterInsertedLines() async throws {
    let workspace = try makeWorkspace()
    try write("alpha\nbeta\ngamma\n", to: "notes.txt", in: workspace)
    let orchestrator = ToolOrchestrator(executorRegistry: .codingAgent)
    let pending = await orchestrator.prepareSameFileEditGroup(
      requests: [
        request(
          .editFile,
          workspace: workspace,
          arguments: editArguments(path: "notes.txt", oldText: "gamma", newText: "GAMMA")
        ),
        request(
          .editFile,
          workspace: workspace,
          arguments: editArguments(
            path: "notes.txt",
            oldText: "alpha",
            newText: "alpha\ninserted"
          )
        ),
      ],
      workspace: workspace
    )

    let completed = await orchestrator.executeApprovedSameFileEditGroup(
      records: pending,
      enforceApprovedScope: true,
      workspace: workspace
    )

    guard case .editFile(.success(let firstReceipt)) = completed[0].resultPayload,
      case .editFile(.success(let secondReceipt)) = completed[1].resultPayload
    else {
      Issue.record("Expected edit_file success payloads.")
      return
    }
    #expect(firstReceipt.oldRange == AppliedEditLineRange(startLine: 3, lineCount: 1))
    #expect(firstReceipt.newRange == AppliedEditLineRange(startLine: 4, lineCount: 1))
    #expect(firstReceipt.diff.text.contains("@@ -3,1 +4,1 @@"))
    #expect(secondReceipt.newRange == AppliedEditLineRange(startLine: 1, lineCount: 2))
    #expect(
      try String(contentsOf: workspace.rootURL.appending(path: "notes.txt"), encoding: .utf8)
        == "alpha\ninserted\nbeta\nGAMMA\n")
  }

  @Test
  func overlappingSameFileEditGroupFailsWithoutWriting() async throws {
    let workspace = try makeWorkspace()
    try write("abcdef\n", to: "notes.txt", in: workspace)
    let orchestrator = ToolOrchestrator(executorRegistry: .codingAgent)

    let records = await orchestrator.prepareSameFileEditGroup(
      requests: [
        request(
          .editFile,
          workspace: workspace,
          arguments: editArguments(path: "notes.txt", oldText: "abc", newText: "ABC")
        ),
        request(
          .editFile,
          workspace: workspace,
          arguments: editArguments(path: "notes.txt", oldText: "bcd", newText: "BCD")
        ),
      ],
      workspace: workspace
    )

    #expect(records.map(\.status) == [.failed, .failed])
    #expect(records.allSatisfy { $0.state.preview?.text.contains("overlap") == true })
    #expect(
      try String(contentsOf: workspace.rootURL.appending(path: "notes.txt"), encoding: .utf8)
        == "abcdef\n")
  }

  @Test
  func approvedSameFileEditGroupRevalidatesCurrentContentBeforeCommitting() async throws {
    let workspace = try makeWorkspace()
    try write("alpha\nbeta\n", to: "notes.txt", in: workspace)
    let orchestrator = ToolOrchestrator(executorRegistry: .codingAgent)
    let pending = await orchestrator.prepareSameFileEditGroup(
      requests: [
        request(
          .editFile,
          workspace: workspace,
          arguments: editArguments(path: "notes.txt", oldText: "alpha", newText: "ALPHA")
        ),
        request(
          .editFile,
          workspace: workspace,
          arguments: editArguments(path: "notes.txt", oldText: "beta", newText: "BETA")
        ),
      ],
      workspace: workspace
    )
    try write("prefix\nalpha\nbeta\n", to: "notes.txt", in: workspace)

    let completed = await orchestrator.executeApprovedSameFileEditGroup(
      records: pending,
      enforceApprovedScope: true,
      workspace: workspace
    )

    #expect(completed.map(\.status) == [.completed, .completed])
    #expect(
      try String(contentsOf: workspace.rootURL.appending(path: "notes.txt"), encoding: .utf8)
        == "prefix\nALPHA\nBETA\n")
  }

  @Test
  func failedApprovedSameFileEditGroupDoesNotPartiallyApplyValidSibling() async throws {
    let workspace = try makeWorkspace()
    try write("alpha\nbeta\n", to: "notes.txt", in: workspace)
    let orchestrator = ToolOrchestrator(executorRegistry: .codingAgent)
    let pending = await orchestrator.prepareSameFileEditGroup(
      requests: [
        request(
          .editFile,
          workspace: workspace,
          arguments: editArguments(path: "notes.txt", oldText: "alpha", newText: "ALPHA")
        ),
        request(
          .editFile,
          workspace: workspace,
          arguments: editArguments(path: "notes.txt", oldText: "beta", newText: "BETA")
        ),
      ],
      workspace: workspace
    )
    try write("alpha\nremoved\n", to: "notes.txt", in: workspace)

    let failed = await orchestrator.executeApprovedSameFileEditGroup(
      records: pending,
      enforceApprovedScope: true,
      workspace: workspace
    )

    #expect(failed.map(\.status) == [.failed, .failed])
    #expect(
      try String(contentsOf: workspace.rootURL.appending(path: "notes.txt"), encoding: .utf8)
        == "alpha\nremoved\n")
  }

  @Test
  func cancelledSameFileEditGroupStopsBeforeAtomicWrite() async throws {
    let workspace = try makeWorkspace()
    try write("alpha\nbeta\n", to: "notes.txt", in: workspace)
    let orchestrator = ToolOrchestrator(executorRegistry: .codingAgent)
    let pending = await orchestrator.prepareSameFileEditGroup(
      requests: [
        request(
          .editFile,
          workspace: workspace,
          arguments: editArguments(path: "notes.txt", oldText: "alpha", newText: "ALPHA")
        ),
        request(
          .editFile,
          workspace: workspace,
          arguments: editArguments(path: "notes.txt", oldText: "beta", newText: "BETA")
        ),
      ],
      workspace: workspace
    )

    let task = Task { () -> [ToolCallRecord] in
      withUnsafeCurrentTask { currentTask in
        currentTask?.cancel()
      }
      return await orchestrator.executeApprovedSameFileEditGroup(
        records: pending,
        enforceApprovedScope: true,
        workspace: workspace
      )
    }
    let cancelled = await task.value

    #expect(cancelled.map(\.status) == [.cancelled, .cancelled])
    #expect(
      try String(contentsOf: workspace.rootURL.appending(path: "notes.txt"), encoding: .utf8)
        == "alpha\nbeta\n")
  }

  @Test
  func editFileAwaitsApprovalWithPreviewWithoutWriting() async throws {
    let workspace = try makeWorkspace()
    try write("let title = \"Old\"\n", to: "Sources/App.swift", in: workspace)

    let result = await ToolOrchestrator(executorRegistry: .codingAgent).execute(
      request: request(
        .editFile,
        workspace: workspace,
        arguments: editArguments(
          path: "Sources/App.swift",
          oldText: "let title = \"Old\"",
          newText: "let title = \"New\""
        )
      ),
      workspace: workspace
    )

    #expect(result.status == .awaitingApproval)
    #expect(result.evaluation.decision == .requiresApproval)
    #expect(
      result.evaluation.normalizedPaths == [
        workspace.rootURL.appending(path: "Sources/App.swift").path(percentEncoded: false)
      ])
    #expect(
      result.evaluation.workspaceRelativePaths == [
        WorkspaceRelativePath(rawValue: "Sources/App.swift")
      ])
    #expect(result.state.preview?.status == .success)
    #expect(result.state.preview?.affectedPaths == ["Sources/App.swift"])
    #expect(result.state.preview?.text.contains("-let title = \"Old\"") == true)
    #expect(result.state.preview?.text.contains("+let title = \"New\"") == true)
    #expect(
      try String(
        contentsOf: workspace.rootURL.appending(path: "Sources/App.swift"), encoding: .utf8)
        == "let title = \"Old\"\n")
  }

  @Test
  func approvedEditFileWritesSingleExactReplacement() async throws {
    let workspace = try makeWorkspace()
    try write("one\ntwo\nthree\n", to: "notes.txt", in: workspace)

    let result = await ToolOrchestrator(executorRegistry: .codingAgent).executeApproved(
      request: request(
        .editFile,
        workspace: workspace,
        arguments: editArguments(path: "notes.txt", oldText: "two", newText: "TWO")
      ),
      workspace: workspace
    )

    #expect(result.status == .completed)
    #expect(result.state.preview?.status == .success)
    #expect(result.state.preview?.text == "Edited notes.txt.")
    guard case .editFile(.success(let receipt)) = result.resultPayload else {
      Issue.record("Expected edit_file success payload.")
      return
    }
    #expect(receipt.path.rawValue == "notes.txt")
    #expect(receipt.matchStrategy == .exact)
    #expect(receipt.oldRange == AppliedEditLineRange(startLine: 2, lineCount: 1))
    #expect(receipt.newRange == AppliedEditLineRange(startLine: 2, lineCount: 1))
    #expect(!receipt.diff.truncated)
    #expect(
      receipt.diff.text == """
        --- a/notes.txt
        +++ b/notes.txt
        @@ -2,1 +2,1 @@
        -two
        +TWO
        """)
    #expect(
      try String(contentsOf: workspace.rootURL.appending(path: "notes.txt"), encoding: .utf8)
        == "one\nTWO\nthree\n")
  }

  @Test
  func approvedEditFileMatchesNormalizedLineEndingsAndPreservesCRLF() async throws {
    let workspace = try makeWorkspace()
    try write("one\r\ntwo\r\nthree\r\n", to: "notes.txt", in: workspace)

    let result = await ToolOrchestrator(executorRegistry: .codingAgent).executeApproved(
      request: request(
        .editFile,
        workspace: workspace,
        arguments: editArguments(path: "notes.txt", oldText: "two\n", newText: "TWO\n")
      ),
      workspace: workspace
    )

    #expect(result.status == .completed)
    guard case .editFile(.success(let receipt)) = result.resultPayload else {
      Issue.record("Expected edit_file success payload.")
      return
    }
    #expect(receipt.matchStrategy == .normalizedLineEndings)
    #expect(receipt.oldRange == AppliedEditLineRange(startLine: 2, lineCount: 1))
    #expect(receipt.newRange == AppliedEditLineRange(startLine: 2, lineCount: 1))
    #expect(!receipt.diff.text.contains("\r"))
    #expect(
      try String(contentsOf: workspace.rootURL.appending(path: "notes.txt"), encoding: .utf8)
        == "one\r\nTWO\r\nthree\r\n")
  }

  @Test
  func approvedEditFileNormalizedMatchMapsDeepCRLFOffset() async throws {
    // Exercises the offset accumulation in IndexedNormalizedText.sourceRanges: the match
    // sits several CRLF graphemes in, so a correct normalized-offset → source-index mapping
    // is required to replace the right line and preserve every other CRLF.
    let workspace = try makeWorkspace()
    try write("alpha\r\nbeta\r\ngamma\r\ndelta\r\nepsilon\r\n", to: "notes.txt", in: workspace)

    let result = await ToolOrchestrator(executorRegistry: .codingAgent).executeApproved(
      request: request(
        .editFile,
        workspace: workspace,
        arguments: editArguments(path: "notes.txt", oldText: "delta\n", newText: "DELTA\n")
      ),
      workspace: workspace
    )

    #expect(result.status == .completed)
    guard case .editFile(.success(let receipt)) = result.resultPayload else {
      Issue.record("Expected edit_file success payload.")
      return
    }
    #expect(receipt.matchStrategy == .normalizedLineEndings)
    #expect(
      try String(contentsOf: workspace.rootURL.appending(path: "notes.txt"), encoding: .utf8)
        == "alpha\r\nbeta\r\ngamma\r\nDELTA\r\nepsilon\r\n")
  }

  @Test
  func approvedEditFileMatchesTrailingWhitespaceDifference() async throws {
    let workspace = try makeWorkspace()
    try write("let value = 1   \nlet done = true\n", to: "Sources/App.swift", in: workspace)

    let result = await ToolOrchestrator(executorRegistry: .codingAgent).executeApproved(
      request: request(
        .editFile,
        workspace: workspace,
        arguments: editArguments(
          path: "Sources/App.swift",
          oldText: "let value = 1\n",
          newText: "let value = 2\n"
        )
      ),
      workspace: workspace
    )

    #expect(result.status == .completed)
    guard case .editFile(.success(let receipt)) = result.resultPayload else {
      Issue.record("Expected edit_file success payload.")
      return
    }
    #expect(receipt.matchStrategy == .trimTrailingWhitespace)
    #expect(
      try String(
        contentsOf: workspace.rootURL.appending(path: "Sources/App.swift"), encoding: .utf8)
        == "let value = 2\nlet done = true\n")
  }

  @Test
  func approvedEditFileMatchesIndentationFlexibleBlock() async throws {
    let workspace = try makeWorkspace()
    try write(
      """
      func run() {
          if ready {
              print("old")
          }
      }
      """,
      to: "Sources/App.swift",
      in: workspace
    )

    let result = await ToolOrchestrator(executorRegistry: .codingAgent).executeApproved(
      request: request(
        .editFile,
        workspace: workspace,
        arguments: editArguments(
          path: "Sources/App.swift",
          oldText:
            """
              if ready {
                  print("old")
              }
            """,
          newText:
            """
              if ready {
                  print("new")
              }
            """
        )
      ),
      workspace: workspace
    )

    #expect(result.status == .completed)
    guard case .editFile(.success(let receipt)) = result.resultPayload else {
      Issue.record("Expected edit_file success payload.")
      return
    }
    #expect(receipt.matchStrategy == .indentationFlexible)
    #expect(
      try String(
        contentsOf: workspace.rootURL.appending(path: "Sources/App.swift"), encoding: .utf8)
          == """
          func run() {
              if ready {
                  print("new")
              }
          }
          """)
  }

  @Test
  func approvedEditFileMatchesLineTrimmedBlock() async throws {
    let workspace = try makeWorkspace()
    try write(
      """
      func run() {
          if ready {
              print("old")
          }
      }
      """,
      to: "Sources/App.swift",
      in: workspace
    )

    let result = await ToolOrchestrator(executorRegistry: .codingAgent).executeApproved(
      request: request(
        .editFile,
        workspace: workspace,
        arguments: editArguments(
          path: "Sources/App.swift",
          oldText:
            """
            if ready {
            print("old")
            }
            """,
          newText:
            """
            if ready {
            print("new")
            }
            """
        )
      ),
      workspace: workspace
    )

    #expect(result.status == .completed)
    guard case .editFile(.success(let receipt)) = result.resultPayload else {
      Issue.record("Expected edit_file success payload.")
      return
    }
    #expect(receipt.matchStrategy == .lineTrimmedBlock)
    #expect(
      try String(
        contentsOf: workspace.rootURL.appending(path: "Sources/App.swift"), encoding: .utf8)
          == """
          func run() {
              if ready {
                  print("new")
              }
          }
          """)
  }

  @Test
  func editFilePreviewUsesFallbackMatchWithoutWriting() async throws {
    let workspace = try makeWorkspace()
    try write("one\r\ntwo\r\nthree\r\n", to: "notes.txt", in: workspace)

    let result = await ToolOrchestrator(executorRegistry: .codingAgent).execute(
      request: request(
        .editFile,
        workspace: workspace,
        arguments: editArguments(path: "notes.txt", oldText: "two\n", newText: "TWO\n")
      ),
      workspace: workspace
    )

    #expect(result.status == .awaitingApproval)
    #expect(result.state.preview?.status == .success)
    #expect(result.state.preview?.text.contains("@@ -2,1 +2,1 @@") == true)
    #expect(result.state.preview?.text.contains("-two") == true)
    #expect(result.state.preview?.text.contains("+TWO") == true)
    #expect(
      try String(contentsOf: workspace.rootURL.appending(path: "notes.txt"), encoding: .utf8)
        == "one\r\ntwo\r\nthree\r\n")
  }

  @Test
  func editFileFallbackAmbiguityFailsBeforeApproval() async throws {
    let workspace = try makeWorkspace()
    try write("let value = 1   \nlet value = 1\t\n", to: "Sources/App.swift", in: workspace)

    let result = await executeEdit(
      path: "Sources/App.swift",
      oldText: "let value = 1\n",
      newText: "let value = 2\n",
      workspace: workspace
    )

    #expect(result.status == .failed)
    #expect(result.state.preview?.text.contains("matched more than once") == true)
  }

  @Test
  func approvalPreviewIsFullWhileFinalReceiptIsBounded() async throws {
    let workspace = try makeWorkspace()
    let oldLines = (1...130).map { "old-\($0)" }
    let newLines = (1...130).map { "new-\($0)" }
    let oldText = oldLines.joined(separator: "\n") + "\n"
    let newText = newLines.joined(separator: "\n") + "\n"
    try write(oldText, to: "large.txt", in: workspace)
    let editRequest = request(
      .editFile,
      workspace: workspace,
      arguments: editArguments(path: "large.txt", oldText: oldText, newText: newText)
    )

    let pending = await ToolOrchestrator(executorRegistry: .codingAgent).execute(
      request: editRequest,
      workspace: workspace
    )

    #expect(pending.status == .awaitingApproval)
    #expect(pending.state.preview?.truncated == false)
    #expect(pending.state.preview?.text.contains("-old-65") == true)
    #expect(pending.state.preview?.text.contains("+new-65") == true)

    let completed = await ToolOrchestrator(executorRegistry: .codingAgent).executeApproved(
      request: editRequest,
      workspace: workspace
    )

    guard case .editFile(.success(let receipt)) = completed.resultPayload else {
      Issue.record("Expected edit_file success payload.")
      return
    }
    #expect(receipt.diff.truncated)
    #expect(receipt.diff.text.utf8.count <= 6 * 1024)
    #expect(receipt.diff.text.contains("[140 changed lines omitted]"))
    #expect(receipt.additions == 130)
    #expect(receipt.deletions == 130)
    #expect(
      try String(contentsOf: workspace.rootURL.appending(path: "large.txt"), encoding: .utf8)
        == newText)
  }

  @Test
  func appliedReceiptRoundTripsAndProjectsWithoutDuplicatingStructuredFacts() async throws {
    let workspace = try makeWorkspace()
    try write("one\ntwo\nthree\n", to: "notes.txt", in: workspace)
    let editRequest = request(
      .editFile,
      workspace: workspace,
      arguments: editArguments(path: "notes.txt", oldText: "two", newText: "TWO")
    )
    let completed = await ToolOrchestrator(executorRegistry: .codingAgent).executeApproved(
      request: editRequest,
      workspace: workspace
    )
    let payload = try #require(completed.resultPayload)
    let persisted = try JSONDecoder().decode(
      ToolResultPayload.self,
      from: JSONEncoder().encode(payload)
    )
    let projection = ToolResultProjector.project(payload: persisted, request: completed.request)
    let rendered = ToolModelObservationRenderer.render(projection, callID: completed.request.id)

    #expect(rendered.contains("\"kind\":\"edit_receipt\""))
    #expect(rendered.contains("\"affected_paths\":[\"notes.txt\"]"))
    #expect(rendered.contains("\"path\":\"notes.txt\""))
    #expect(rendered.contains("\"match_strategy\":\"exact\""))
    #expect(rendered.contains("\"replacements\":1"))
    #expect(rendered.contains("\"old_start_line\":2"))
    #expect(rendered.contains("\"old_line_count\":1"))
    #expect(rendered.contains("\"new_start_line\":2"))
    #expect(rendered.contains("\"new_line_count\":1"))
    #expect(rendered.contains("\"additions\":1"))
    #expect(rendered.contains("\"deletions\":1"))
    #expect(rendered.contains("\"diff_truncated\":false"))
    #expect(rendered.contains("CONTENT:\n--- a/notes.txt"))
    #expect(!rendered.contains("Edited file:"))
    #expect(!rendered.contains("Match strategy:"))
    #expect(!rendered.contains("Diff summary:"))
  }

  @Test
  func approvedEditFileRevalidatesWithCurrentFallbackStrategy() async throws {
    let workspace = try makeWorkspace()
    try write("let value = 1\n", to: "Sources/App.swift", in: workspace)
    let pending = await executeEdit(
      path: "Sources/App.swift",
      oldText: "let value = 1\n",
      newText: "let value = 2\n",
      workspace: workspace
    )
    try write("let value = 1   \n", to: "Sources/App.swift", in: workspace)

    let result = await ToolOrchestrator(executorRegistry: .codingAgent).executeApproved(
      request: pending.request,
      workspace: workspace
    )

    #expect(pending.status == .awaitingApproval)
    #expect(pending.state.preview?.text.contains("-let value = 1\n") == true)
    #expect(pending.state.preview?.text.contains("-let value = 1   \n") == false)
    #expect(result.status == .completed)
    guard case .editFile(.success(let receipt)) = result.resultPayload else {
      Issue.record("Expected edit_file success payload.")
      return
    }
    #expect(receipt.matchStrategy == .trimTrailingWhitespace)
    #expect(receipt.diff.text.contains("-let value = 1   \n"))
    #expect(
      try String(
        contentsOf: workspace.rootURL.appending(path: "Sources/App.swift"), encoding: .utf8)
        == "let value = 2\n")
  }

  @Test
  func editFileDeniesWorkspaceEscapes() async throws {
    let workspace = try makeWorkspace()

    let result = await ToolOrchestrator(executorRegistry: .codingAgent).execute(
      request: request(
        .editFile,
        workspace: workspace,
        arguments: editArguments(path: "../secret.txt", oldText: "old", newText: "new")
      ),
      workspace: workspace
    )

    #expect(result.status == .denied)
    #expect(result.state.preview?.status == .denied)
  }

  @Test
  func editFileFailsBeforeApprovalForMissingAndAmbiguousOldText() async throws {
    let workspace = try makeWorkspace()
    try write("repeat\nrepeat\n", to: "repeat.txt", in: workspace)
    try write("aaa", to: "overlap.txt", in: workspace)
    try write("hello", to: "hello.txt", in: workspace)

    let missing = await executeEdit(
      path: "hello.txt",
      oldText: "absent",
      newText: "new",
      workspace: workspace
    )
    let ambiguous = await executeEdit(
      path: "repeat.txt",
      oldText: "repeat",
      newText: "value",
      workspace: workspace
    )
    let overlapping = await executeEdit(
      path: "overlap.txt",
      oldText: "aa",
      newText: "b",
      workspace: workspace
    )
    #expect(missing.status == .failed)
    #expect(missing.state.preview?.text.contains("old_text was not found") == true)
    #expect(ambiguous.status == .failed)
    #expect(ambiguous.state.preview?.text.contains("matched more than once") == true)
    #expect(overlapping.status == .failed)
    #expect(overlapping.state.preview?.text.contains("matched more than once") == true)
  }

  @Test
  func editFileFailsBeforeApprovalForIdenticalEmptyAndInvalidText() async throws {
    let workspace = try makeWorkspace()
    try write("hello", to: "hello.txt", in: workspace)
    try Data([0xff, 0xfe]).write(to: workspace.rootURL.appending(path: "binary.txt"))

    let identical = await executeEdit(
      path: "hello.txt",
      oldText: "hello",
      newText: "hello",
      workspace: workspace
    )
    let emptyOldText = await executeEdit(
      path: "hello.txt",
      oldText: "",
      newText: "new",
      workspace: workspace
    )
    let nonUTF8 = await executeEdit(
      path: "binary.txt",
      oldText: "old",
      newText: "new",
      workspace: workspace
    )

    #expect(identical.status == .failed)
    #expect(identical.state.preview?.text.contains("different from old_text") == true)
    #expect(emptyOldText.status == .failed)
    #expect(emptyOldText.state.preview?.text.contains("must not be empty") == true)
    #expect(nonUTF8.status == .failed)
    #expect(nonUTF8.state.preview?.text.contains("not valid UTF-8") == true)
  }

  @Test
  func editFileOldTextNotFoundBeforeApprovalReturnsStructuredRecoveryPayload() async throws {
    let workspace = try makeWorkspace()
    try write("clock = pygame.time.Clock()\n", to: "pong.py", in: workspace)

    let result = await executeEdit(
      path: "pong.py",
      oldText: "clock = pygame.Krotron(FPS)",
      newText: "clock = pygame.time.Clock()",
      workspace: workspace
    )

    #expect(result.status == .failed)
    #expect(result.state.preview?.status == .failed)
    #expect(result.state.preview?.text.contains("old_text was not found") == true)
    #expect(result.state.preview?.text.contains("Current file excerpt:") == true)
    #expect(result.state.preview?.text.contains("clock = pygame.time.Clock()") == true)
    guard
      case .editFile(.oldTextNotFound(let path, let currentContent, let recovery)) =
        result.resultPayload
    else {
      Issue.record("Expected old_text not found payload before approval.")
      return
    }
    #expect(path == WorkspaceRelativePath(rawValue: "pong.py"))
    #expect(currentContent?.text == "clock = pygame.time.Clock()\n")
    #expect(recovery == .readFile(path: WorkspaceRelativePath(rawValue: "pong.py")))
  }

  @Test
  func approvedEditFileRevalidatesMissingAndAmbiguousOldText() async throws {
    let missingWorkspace = try makeWorkspace()
    try write("old", to: "notes.txt", in: missingWorkspace)
    let pendingMissing = await executeEdit(
      path: "notes.txt",
      oldText: "old",
      newText: "new",
      workspace: missingWorkspace
    )
    try write("changed", to: "notes.txt", in: missingWorkspace)

    let missing = await ToolOrchestrator(executorRegistry: .codingAgent).executeApproved(
      request: pendingMissing.request,
      workspace: missingWorkspace
    )

    let ambiguousWorkspace = try makeWorkspace()
    try write("old", to: "notes.txt", in: ambiguousWorkspace)
    let pendingAmbiguous = await executeEdit(
      path: "notes.txt",
      oldText: "old",
      newText: "new",
      workspace: ambiguousWorkspace
    )
    try write("old old", to: "notes.txt", in: ambiguousWorkspace)

    let ambiguous = await ToolOrchestrator(executorRegistry: .codingAgent).executeApproved(
      request: pendingAmbiguous.request,
      workspace: ambiguousWorkspace
    )

    #expect(pendingMissing.status == .awaitingApproval)
    #expect(missing.status == .failed)
    #expect(missing.state.preview?.text.contains("old_text was not found") == true)
    guard
      case .editFile(.oldTextNotFound(let missingPath, let currentContent, let recovery)) =
        missing.resultPayload
    else {
      Issue.record("Expected old_text not found payload.")
      return
    }
    #expect(missingPath.rawValue == "notes.txt")
    #expect(currentContent?.text == "changed")
    #expect(recovery == .readFile(path: WorkspaceRelativePath(rawValue: "notes.txt")))
    #expect(pendingAmbiguous.status == .awaitingApproval)
    #expect(ambiguous.status == .failed)
    #expect(ambiguous.state.preview?.text.contains("matched more than once") == true)
    guard
      case .editFile(.multipleMatches(let ambiguousPath, let matchCount, _)) =
        ambiguous.resultPayload
    else {
      Issue.record("Expected multiple matches payload.")
      return
    }
    #expect(ambiguousPath.rawValue == "notes.txt")
    #expect(matchCount == 2)
  }

  @Test
  func editFileMissingTargetIncludesSuggestionsBeforeApproval() async throws {
    let workspace = try makeWorkspace()
    try write("html", to: "index.html", in: workspace)

    let missing = await executeEdit(
      path: "landing.html",
      oldText: "<h1>Old</h1>",
      newText: "<h1>New</h1>",
      workspace: workspace
    )

    #expect(missing.status == .failed)
    #expect(missing.state.preview?.text.contains("File not found: landing.html") == true)
    #expect(missing.state.preview?.text.contains("Did you mean one of these?") == true)
    #expect(missing.state.preview?.text.contains("index.html") == true)
    #expect(missing.state.preview?.affectedPaths == ["landing.html"])
  }

  @Test
  func approvedEditFileMissingTargetRevalidatesWithSuggestions() async throws {
    let workspace = try makeWorkspace()
    try write("old", to: "notes.txt", in: workspace)
    try write("fallback", to: "notes-backup.txt", in: workspace)

    let pending = await executeEdit(
      path: "notes.txt",
      oldText: "old",
      newText: "new",
      workspace: workspace
    )
    try FileManager.default.removeItem(at: workspace.rootURL.appending(path: "notes.txt"))

    let missing = await ToolOrchestrator(executorRegistry: .codingAgent).executeApproved(
      request: pending.request,
      workspace: workspace
    )

    #expect(pending.status == .awaitingApproval)
    #expect(missing.status == .failed)
    #expect(missing.state.preview?.text.contains("File not found: notes.txt") == true)
    #expect(missing.state.preview?.text.contains("notes-backup.txt") == true)
    guard
      case .editFile(.failed(let path, .fileNotFound(_, let suggestions))) =
        missing.resultPayload
    else {
      Issue.record("Expected edit_file missing target payload with suggestions.")
      return
    }
    #expect(path == WorkspaceRelativePath(rawValue: "notes.txt"))
    #expect(suggestions.first?.path == WorkspaceRelativePath(rawValue: "notes-backup.txt"))
  }

  @Test
  func editFileIsOnlyRegisteredForCodingAgent() {
    #expect(!ToolExecutorRegistry.readOnly.definitions.map(\.name).contains(.editFile))
    #expect(ToolExecutorRegistry.codingAgent.definitions.map(\.name).contains(.editFile))
  }

  private func executeEdit(
    path: String,
    oldText: String,
    newText: String,
    workspace: Workspace
  ) async -> ToolCallRecord {
    await ToolOrchestrator(executorRegistry: .codingAgent).execute(
      request: request(
        .editFile,
        workspace: workspace,
        arguments: editArguments(path: path, oldText: oldText, newText: newText)
      ),
      workspace: workspace
    )
  }

  private func editArguments(
    path: String,
    oldText: String,
    newText: String
  ) -> ToolCallArguments {
    [
      "path": .string(path),
      "old_text": .string(oldText),
      "new_text": .string(newText),
    ]
  }

  private func request(
    _ toolName: ToolName,
    workspace: Workspace,
    arguments: ToolCallArguments
  ) -> RawToolCallRequest {
    RawToolCallRequest(
      workspaceID: workspace.id,
      sessionID: UUID(),
      toolName: toolName,
      arguments: arguments
    )
  }

  private func makeWorkspace() throws -> Workspace {
    let rootURL = try scopedTemporaryDirectory()
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    return Workspace(
      name: "Project",
      rootURL: URL(filePath: Workspace.normalizedPath(for: rootURL))
    )
  }

  private func write(_ content: String, to path: String, in workspace: Workspace) throws {
    let url = workspace.rootURL.appending(path: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try content.write(to: url, atomically: true, encoding: .utf8)
  }
}

struct AppliedEditReceiptBuilderTests {
  @Test
  func wholeFirstLineDeletionUsesUnifiedDiffZeroAnchor() throws {
    let content = "alpha\nbeta\n"
    let range = try #require(content.range(of: "alpha\n"))

    let receipt = AppliedEditReceiptBuilder(policy: .unbounded).build(
      path: WorkspaceRelativePath(rawValue: "notes.txt"),
      originalContent: content,
      matchedRange: range,
      replacementText: "",
      matchStrategy: .exact
    )

    #expect(receipt.oldRange == AppliedEditLineRange(startLine: 1, lineCount: 1))
    #expect(receipt.newRange == AppliedEditLineRange(startLine: 0, lineCount: 0))
    #expect(
      receipt.diff.text == """
        --- a/notes.txt
        +++ b/notes.txt
        @@ -1,1 +0,0 @@
        -alpha
        """)
  }

  @Test
  func partialFinalLineReceiptIncludesFullLineAndNoNewlineMarkers() throws {
    let content = "prefix old suffix"
    let range = try #require(content.range(of: "old"))

    let receipt = AppliedEditReceiptBuilder(policy: .unbounded).build(
      path: WorkspaceRelativePath(rawValue: "notes.txt"),
      originalContent: content,
      matchedRange: range,
      replacementText: "new",
      matchStrategy: .exact
    )

    #expect(receipt.oldRange == AppliedEditLineRange(startLine: 1, lineCount: 1))
    #expect(receipt.newRange == AppliedEditLineRange(startLine: 1, lineCount: 1))
    #expect(
      receipt.diff.text == """
        --- a/notes.txt
        +++ b/notes.txt
        @@ -1,1 +1,1 @@
        -prefix old suffix
        \\ No newline at end of file
        +prefix new suffix
        \\ No newline at end of file
        """)
  }

  @Test
  func removedLineEndingExpandsThroughMergedSuffixLine() throws {
    let content = "alpha\nbeta\n"
    let range = try #require(content.range(of: "\n"))

    let receipt = AppliedEditReceiptBuilder(policy: .unbounded).build(
      path: WorkspaceRelativePath(rawValue: "notes.txt"),
      originalContent: content,
      matchedRange: range,
      replacementText: "",
      matchStrategy: .exact
    )

    #expect(receipt.oldRange == AppliedEditLineRange(startLine: 1, lineCount: 2))
    #expect(receipt.newRange == AppliedEditLineRange(startLine: 1, lineCount: 1))
    #expect(receipt.diff.text.contains("-alpha\n-beta\n+alphabeta"))
  }

  @Test
  func unusualPathIsJSONQuotedInDiffHeaders() throws {
    let content = "old\n"
    let range = try #require(content.range(of: "old"))

    let receipt = AppliedEditReceiptBuilder(policy: .unbounded).build(
      path: WorkspaceRelativePath(rawValue: "dir/a\t\"b\".txt"),
      originalContent: content,
      matchedRange: range,
      replacementText: "new",
      matchStrategy: .exact
    )

    #expect(receipt.diff.text.hasPrefix("--- \"a/dir/a\\t\\\"b\\\".txt\""))
    #expect(receipt.diff.text.contains("+++ \"b/dir/a\\t\\\"b\\\".txt\""))
  }
}
