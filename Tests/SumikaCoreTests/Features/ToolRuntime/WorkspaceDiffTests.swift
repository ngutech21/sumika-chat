import Foundation
import SumikaTestSupport
import Testing

@testable import SumikaCore

@Suite(TemporaryDirectoryTrait(named: "workspace-diff"))
struct WorkspaceDiffTests {
  @Test
  func stagedUnstagedAndUnbornChangesRemainSeparate() async throws {
    let workspace = try repository()
    try write("first\n", "new.txt", in: workspace)
    try await git(["add", "new.txt"], workspace)
    var result = try await snapshot(workspace)
    #expect(result.files[0].staged?.additions == 1)
    #expect(result.files[0].staged?.patch.text.contains("+first") == true)
    try await commit(workspace)
    try write("staged\n", "new.txt", in: workspace)
    try await git(["add", "new.txt"], workspace)
    try write("unstaged\n", "new.txt", in: workspace)
    result = try await snapshot(workspace)
    #expect(result.files.count == 1)
    #expect(result.files[0].staged?.patch.text.contains("+staged") == true)
    #expect(result.files[0].unstaged?.patch.text.contains("+unstaged") == true)
    #expect(result.files[0].staged?.additions == 1)
    #expect(result.files[0].unstaged?.deletions == 1)
    let summary = try #require(rendered(result).json["summary"] as? [String: Any])
    #expect((summary["staged"] as? [String: Any])?["additions"] as? Int == 1)
    #expect((summary["unstaged"] as? [String: Any])?["deletions"] as? Int == 1)
    #expect(WorkspaceDiffPresentation.display(result).text.contains("Staged totals: +1/-1"))
  }

  @Test
  func renamesDeletionsAndModeChangesKeepTheirMetadata() async throws {
    let workspace = try repository()
    for path in ["old.txt", "deleted.txt", "mode.txt"] { try write("old\n", path, in: workspace) }
    try await commit(workspace)
    try await git(["mv", "old.txt", "new.txt"], workspace)
    try FileManager.default.removeItem(at: workspace.rootURL.appending(path: "deleted.txt"))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: workspace.rootURL.appending(path: "mode.txt").path)
    let result = try await snapshot(workspace)
    #expect(result.files.map(\.path.rawValue) == ["deleted.txt", "mode.txt", "new.txt"])
    #expect(result.files[0].unstaged?.kind == .deleted)
    #expect(result.files[1].unstaged?.additions == 0)
    #expect(result.files[2].staged?.kind == .renamed)
    #expect(result.files[2].staged?.originalPath?.rawValue == "old.txt")
  }

  @Test
  func stagedDeletionAndUntrackedReplacementShareOneFileRecord() async throws {
    let workspace = try repository()
    try write("old\n", "file.txt", in: workspace)
    try await commit(workspace)
    try await git(["rm", "--cached", "file.txt"], workspace)
    try write("replacement\n", "file.txt", in: workspace)
    let result = try await snapshot(workspace)
    #expect(result.files.count == 1)
    #expect(result.files[0].staged?.kind == .deleted)
    #expect(result.files[0].staged?.deletions == 1)
    #expect(result.files[0].unstaged?.kind == .untracked)
    #expect(result.files[0].unstaged?.patch.text == "+replacement")
  }

  @Test
  func largeFirstFileCannotHideLaterPatchesInDisplayOrModel() async throws {
    let workspace = try repository()
    for path in ["a-large.txt", "z-small.txt"] { try write("old\n", path, in: workspace) }
    try await commit(workspace)
    try write(String(repeating: "large change\n", count: 15_000), "a-large.txt", in: workspace)
    try write("later-sentinel\n", "z-small.txt", in: workspace)
    let result = try await snapshot(workspace)
    #expect(result.files[0].truncated)
    #expect(result.files[0].unstaged?.patch.text.utf8.count ?? 0 <= 4096)
    #expect(result.files[1].unstaged?.patch.text.contains("+later-sentinel") == true)
    let output = WorkspaceDiffPresentation.display(result)
    #expect(output.text.contains("+later-sentinel"))
    #expect(output.text.utf8.count <= 48 * 1024)
    let model = try rendered(result)
    #expect(model.text.count <= 8000)
    #expect(model.text.contains("+later-sentinel"))
    #expect(model.json["truncated"] as? Bool == true)
    let files = try #require(model.json["files"] as? [[String: Any]])
    #expect(files.count == 2)
    #expect(files[0]["patch_truncated"] as? Bool == true)
    #expect(files[1]["path"] as? String == "z-small.txt")
  }

  @Test
  func untrackedFilesHaveBoundedTextOrExplicitOmissions() async throws {
    let workspace = try repository()
    try write("new file\n", "dir/new.txt", in: workspace)
    try write(String(repeating: "x", count: 100_000), "large.txt", in: workspace)
    try Data([0, 1, 2]).write(to: workspace.rootURL.appending(path: "binary.dat"))
    try FileManager.default.createSymbolicLink(
      at: workspace.rootURL.appending(path: "link"),
      withDestinationURL: URL(filePath: "/etc/passwd"))
    let result = try await snapshot(workspace)
    #expect(
      result.files.map(\.path.rawValue) == ["binary.dat", "dir/new.txt", "large.txt", "link"])
    #expect(result.files[0].unstaged?.omission == .binary)
    #expect(result.files[0].unstaged?.additions == nil)
    #expect(result.files[1].unstaged?.additions == 1)
    #expect(result.files[1].unstaged?.patch.text == "+new file")
    #expect(result.files[2].unstaged?.additions == nil)
    #expect(result.files[2].truncated)
    #expect(result.files[3].unstaged?.omission == .symlink)
    #expect(!WorkspaceDiffPresentation.display(result).text.contains("root:"))
  }

  @Test
  func binaryTrackedFilesHaveNoPatchData() async throws {
    let workspace = try repository()
    try Data([0, 1]).write(to: workspace.rootURL.appending(path: "binary.dat"))
    try await commit(workspace)
    try Data([0, 2]).write(to: workspace.rootURL.appending(path: "binary.dat"))
    let result = try await snapshot(workspace)
    #expect(result.files[0].unstaged?.omission == .binary)
    #expect(result.files[0].unstaged?.patch.text == "")
    #expect(result.files[0].truncated == false)
  }

  @Test(arguments: ["\n", "\r\n"], [false, true])
  func untrackedLineEndingsPreserveCountsAndPatchLines(
    lineEnding: String, trailingNewline: Bool
  ) async throws {
    let workspace = try repository()
    let text = "one\(lineEnding)two" + (trailingNewline ? lineEnding : "")
    try write(text, "new.txt", in: workspace)

    let result = try await snapshot(workspace)
    let change = try #require(result.files.first?.unstaged)
    #expect(change.additions == 2)
    #expect(change.patch.text == "+one\n+two")
    #expect(!change.patch.truncated)
  }

  @Test
  func unusualNamesAndLiteralPathspecsRemainDistinct() async throws {
    let workspace = try repository()
    let paths = [
      "[literal].txt", "l.txt", "space name.txt", "tab\tname.txt", "line\nname.txt", " leading.txt",
    ]
    for path in paths { try write("old\n", path, in: workspace) }
    try await commit(workspace)
    for path in paths { try write("new\n", path, in: workspace) }
    let result = try await snapshot(workspace)
    #expect(Set(result.files.map(\.path.rawValue)) == Set(paths))
    #expect(result.files.allSatisfy { $0.unstaged?.patch.text.contains("+new") == true })
    let scoped = try await snapshot(workspace, path: "[literal].txt")
    #expect(scoped.files.map(\.path.rawValue) == ["[literal].txt"])
    #expect(!WorkspaceDiffPresentation.display(scoped).text.contains("b/l.txt"))
    let spaced = try await snapshot(workspace, path: " leading.txt")
    #expect(spaced.files.map(\.path.rawValue) == [" leading.txt"])
    let receipt = ToolReceiptFactory.make(
      callID: UUID(), toolName: .workspaceDiff,
      preview: WorkspaceDiffResult.snapshot(spaced).preview)
    #expect(receipt?.affectedPaths.map(\.rawValue) == [" leading.txt"])
    _ = try rendered(result)
  }

  @Test(arguments: [" leading.txt", "trailing.txt "])
  func literalWhitespaceScopesRemainDistinctDuringDuplicateDetection(path: String) async throws {
    let workspace = try repository()
    let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
    try write("ordinary file\n", trimmedPath, in: workspace)
    try write("literal whitespace file\n", path, in: workspace)
    let assistantID = UUID()
    let request = ToolLoopRequest(
      workspace: workspace, sessionID: UUID(), turnID: UUID(), assistantMessageID: assistantID,
      items: [
        .userMessage(.init(content: "Compare these files")),
        .assistantMessage(.init(id: assistantID, content: "")),
      ],
      nativeToolCalls: [trimmedPath, path, workspace.rootURL.appending(path: path).absoluteString]
        .map { ChatRuntimeToolCall(name: "workspace_diff", arguments: ["path": .string($0)]) })
    let result = try await ToolLoopCoordinator().run(
      request,
      using: ToolOrchestrator(
        executorRegistry: ToolExecutorRegistry([AnyToolExecutor(WorkspaceDiffToolExecutor())])))
    let records = (result?.events ?? []).compactMap { event -> ToolCallRecord? in
      guard case .toolCallAppended(let record, _) = event else { return nil }
      return record
    }
    try #require(records.count == 3)
    guard case .workspaceDiff(.snapshot(let ordinary)) = records[0].resultPayload,
      case .workspaceDiff(.snapshot(let literal)) = records[1].resultPayload
    else {
      Issue.record("Distinct literal paths must execute independently.")
      return
    }
    #expect(ordinary.files.map(\.path.rawValue) == [trimmedPath])
    #expect(literal.files.map(\.path.rawValue) == [path])
    #expect(literal.files.first?.unstaged?.patch.text == "+literal whitespace file")
    guard case .duplicateToolCall(let duplicate) = records[2].resultPayload else {
      Issue.record("A file URL for the same literal path must replay its completed result.")
      return
    }
    #expect(duplicate.previousCallID == records[1].id)
    #expect(duplicate.affectedPaths.map(\.rawValue) == [path])
    #expect(duplicate.replayedObservation != nil)
    #expect(!duplicate.blocked)
  }

  @Test(arguments: [true, false])
  func crossScopeRenamesNeverExposeOtherEndpoint(incoming: Bool) async throws {
    let workspace = try repository()
    let old = incoming ? "outside-private.txt" : "inside/old.txt"
    let new = incoming ? "inside/new.txt" : "outside-private.txt"
    try write("old\n", old, in: workspace)
    try FileManager.default.createDirectory(
      at: workspace.rootURL.appending(path: "inside"), withIntermediateDirectories: true)
    try await commit(workspace)
    try await git(["mv", old, new], workspace)
    let result = try await snapshot(workspace, path: "inside")
    #expect(result.files.count == 1)
    #expect(result.files[0].staged?.kind == (incoming ? .added : .deleted))
    #expect(result.files[0].staged?.originalPath == nil)
    #expect(!WorkspaceDiffPresentation.display(result).text.contains("outside-private"))
    #expect(!(try rendered(result).text).contains("outside-private"))
    let nested = Workspace(name: "inside", rootURL: workspace.rootURL.appending(path: "inside"))
    let nestedResult = try await snapshot(nested)
    #expect(nestedResult.files[0].path.rawValue == (incoming ? "new.txt" : "old.txt"))
    #expect(!WorkspaceDiffPresentation.display(nestedResult).text.contains("outside-private"))
  }

  @Test
  func modelMetadataOverflowIsExplicitAndNeverBreaksJSON() throws {
    let result = WorkspaceDiffSnapshot(
      path: nil,
      files: (0..<100).map { index in
        WorkspaceDiffFile(
          path: .init(
            rawValue: String(format: "%03d-", index) + String(repeating: "long", count: 20)),
          unstaged: .init(
            kind: .modified, additions: 1, deletions: 1, patch: .init(text: "+new\n-old")))
      })
    let model = try rendered(result)
    #expect(model.text.count <= 8000)
    #expect(model.json["truncated"] as? Bool == true)
    let files = try #require(model.json["files"] as? [[String: Any]])
    #expect(files.count > 0)
    #expect(files.count < 100)
    #expect(model.json["omitted_files"] as? Int == 100 - files.count)
    let display = WorkspaceDiffPresentation.display(result, maxBytes: 1000)
    #expect(display.text.utf8.count <= 1000)
    #expect(display.text.contains("Omitted files:"))
  }

  @Test
  func projectionIsDerivedAndRoundTripPreservesStructuredResult() throws {
    let result = WorkspaceDiffSnapshot(
      path: .init(rawValue: "src"),
      files: [
        .init(
          path: .init(rawValue: "src/a"),
          staged: .init(
            kind: .modified, additions: 1, deletions: 2,
            patch: .init(text: "+hello", truncated: true, redacted: true)))
      ])
    let payload = ToolResultPayload.workspaceDiff(.snapshot(result))
    let data = try JSONEncoder().encode(payload)
    #expect(try JSONDecoder().decode(ToolResultPayload.self, from: data) == payload)
    let object = try #require(String(data: data, encoding: .utf8))
    #expect(!object.contains("files_changed"))
    #expect(!object.contains("Changed files:"))
    let model = try rendered(result)
    #expect(model.json["redacted"] as? Bool == true)
  }

  @Test
  func duplicateReplayPreservesLaterFileAndControlMetadata() throws {
    let result = WorkspaceDiffSnapshot(
      path: nil,
      files: [
        .init(
          path: .init(rawValue: "a"),
          unstaged: .init(
            kind: .modified, additions: 10, deletions: 0,
            patch: .init(text: String(repeating: "+large\n", count: 580), truncated: true))),
        .init(
          path: .init(rawValue: "z"),
          unstaged: .init(
            kind: .modified, additions: 1, deletions: 0, patch: .init(text: "+last-sentinel"))),
      ])
    var large = result
    large.files[0].staged = .init(
      kind: .modified, additions: 1, deletions: 1,
      patch: .init(text: "+stage-sentinel\n" + String(repeating: "s", count: 2048)))
    large.files[0].unstaged = .init(
      kind: .modified, additions: 1, deletions: 1,
      patch: .init(text: "+unstaged-sentinel\n" + String(repeating: "u", count: 2048)))
    for name in ["b", "c", "d"] {
      var file = result.files[0]
      file.path = .init(rawValue: name)
      large.files.insert(file, at: large.files.count - 1)
    }
    let original = WorkspaceDiffPresentation.projection(large)
    let duplicate = DuplicateToolCallResult(
      previousCallID: UUID(), message: "Repeated diff", replayedObservation: original.observation)
    let projection = ToolResultProjector.project(
      payload: .duplicateToolCall(duplicate), request: request())
    let text = ToolModelObservationRenderer.render(
      projection, callID: UUID(), modelFollowUpNotice: String(repeating: "notice ", count: 2000))
    let json = try jsonHeader(text)
    #expect(text.count <= 8000)
    #expect(text.contains("+last-sentinel"))
    #expect(text.contains("+stage-sentinel"))
    #expect(text.contains("+unstaged-sentinel"))
    #expect(json["duplicate"] as? Bool == true)
    #expect(json["not_reexecuted"] as? Bool == true)
  }

  @Test
  func duplicateReplayKeepsFlagsFromLaterFiles() throws {
    let snapshot = WorkspaceDiffSnapshot(
      path: nil,
      files: [
        .init(
          path: .init(rawValue: "a"),
          unstaged: .init(
            kind: .modified, patch: .init(text: "+first"))),
        .init(
          path: .init(rawValue: "z"),
          unstaged: .init(
            kind: .modified, patch: .init(text: "+last", truncated: true, redacted: true))),
      ])
    let duplicate = DuplicateToolCallResult(
      previousCallID: UUID(), message: "Repeated diff",
      replayedObservation: WorkspaceDiffPresentation.projection(snapshot).observation)
    let projection = ToolResultProjector.project(
      payload: .duplicateToolCall(duplicate), request: request())
    let json = try jsonHeader(ToolModelObservationRenderer.render(projection, callID: UUID()))
    #expect(json["truncated"] as? Bool == true)
    #expect(json["redacted"] as? Bool == true)
  }

  @Test
  func processCaptureAndConcurrencyRemainBounded() async throws {
    let workspace = try repository()
    for index in 0..<6 { try write("old\n", "file-\(index)", in: workspace) }
    try await commit(workspace)
    for index in 0..<6 { try write("new\n", "file-\(index)", in: workspace) }
    let indexURL = workspace.rootURL.appending(path: ".git/index")
    let originalIndex = try Data(contentsOf: indexURL)
    let runner = DiffRecordingRunner()
    let payload = await WorkspaceDiffToolExecutor(processRunner: runner).run(
      .init(), context: .init(workspace: workspace))
    #expect(payload.status == .success)
    #expect(try Data(contentsOf: indexURL) == originalIndex)
    #expect(await runner.maximumActive <= 2)
    #expect(
      await runner.requests.allSatisfy {
        $0.maxStdoutBytes <= 48 * 1024 && $0.maxStderrBytes == 8 * 1024
      })
    #expect(
      await runner.requests.allSatisfy {
        $0.arguments.contains("--literal-pathspecs") && $0.arguments.contains("--no-optional-locks")
      })
  }

  @Test
  func overallDeadlineCancelsTheRunner() async throws {
    let workspace = try repository()
    let runner = DiffSleepingRunner()
    let result = await WorkspaceDiffToolExecutor(
      requestTimeout: .milliseconds(30), processRunner: runner
    )
    .run(.init(), context: .init(workspace: workspace))
    #expect(result.status == .failed)
    #expect(result.text.contains("request timed out"))
    #expect(await runner.cancelled)
  }

  @Test
  func cleanInventorySkipsAllOtherGitWork() async throws {
    let workspace = try repository()
    let runner = DiffRecordingRunner()
    let result = await WorkspaceDiffToolExecutor(processRunner: runner).run(
      .init(), context: .init(workspace: workspace))
    #expect(result.text == "No workspace changes.")
    #expect(await runner.requests.count == 1)
  }

  @Test(arguments: [
    DiffFailureMode.statFailure, .statTruncation, .duplicateStatistics,
    .malformedStatus, .patchFailure,
  ])
  func collectionFailuresNeverReturnPartialSuccess(mode: DiffFailureMode) async throws {
    let workspace = try repository()
    try write("old\n", "tracked.txt", in: workspace)
    try await commit(workspace)
    try write("new\n", "tracked.txt", in: workspace)
    let runner = DiffRecordingRunner(failure: mode)
    let result = await WorkspaceDiffToolExecutor(processRunner: runner).run(
      .init(), context: .init(workspace: workspace))
    #expect(result.status == .failed)
    if mode == .statTruncation || mode == .duplicateStatistics || mode == .malformedStatus {
      #expect(result.text.contains("narrower path"))
    }
  }

  @Test
  func nonUTF8PatchesAreOmittedAndUTF8BoundariesRemainValid() async throws {
    let workspace = try repository()
    try write("old\n", "encoded.txt", in: workspace)
    try await commit(workspace)
    try Data([0xff, 0xfe, 0xe9, 10]).write(to: workspace.rootURL.appending(path: "encoded.txt"))
    try write(String(repeating: "🐈", count: 20_000), "unicode.txt", in: workspace)
    let result = try await snapshot(workspace)
    #expect(result.files[0].unstaged?.omission == .binary)
    let preview = try #require(result.files[1].unstaged?.patch)
    #expect(preview.text.utf8.count <= 4096)
    #expect(preview.truncated)
    #expect(!preview.text.contains("\u{FFFD}"))
    _ = try rendered(result)
  }

  @Test
  func trackedSymlinksAndSubmodulesRemainMetadataOnly() async throws {
    let workspace = try repository()
    let moduleURL = workspace.rootURL.appending(path: "module")
    try FileManager.default.createDirectory(at: moduleURL, withIntermediateDirectories: true)
    let child = Workspace(name: "Module", rootURL: moduleURL)
    try await git(["init", "-q"], child)
    try write("module\n", "file", in: child)
    try await commit(child)
    let linkURL = workspace.rootURL.appending(path: "link")
    try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: "before")
    try await commit(workspace)
    try FileManager.default.removeItem(at: linkURL)
    try FileManager.default.createSymbolicLink(
      atPath: linkURL.path, withDestinationPath: "/etc/passwd")
    try Data("changed\n".utf8).write(to: moduleURL.appending(path: "file"))
    let result = try await snapshot(workspace)
    #expect(result.files.map(\.path.rawValue) == ["link", "module"])
    #expect(result.files[0].unstaged?.omission == .symlink)
    #expect(result.files[1].unstaged?.omission == .submodule)
    #expect(
      result.files.allSatisfy {
        $0.changes.allSatisfy { $0.patch.text.isEmpty && $0.additions == nil }
      })
  }

  @Test(arguments: [false, true])
  func conflictsRetainTheirStatusWithoutInventedStatistics(includeOrdinaryChanges: Bool)
    async throws
  {
    let workspace = try repository()
    try write("base\n", "file", in: workspace)
    if includeOrdinaryChanges { try write("base\n", "ordinary.txt", in: workspace) }
    try await commit(workspace)
    try await git(["branch", "-m", "base"], workspace)
    try await git(["checkout", "-qb", "side"], workspace)
    try write("side\n", "file", in: workspace)
    try await commit(workspace)
    try await git(["checkout", "-q", "base"], workspace)
    try write("main\n", "file", in: workspace)
    try await commit(workspace)
    let merged = try await DefaultCommandProcessRunner().run(
      .init(
        executableURL: URL(filePath: "/usr/bin/git"),
        arguments: [
          "-C", workspace.rootURL.path, "-c", "user.name=Test", "-c",
          "user.email=test@example.invalid", "merge", "side",
        ],
        environment: ProcessInfo.processInfo.environment, workingDirectoryURL: workspace.rootURL,
        timeoutSeconds: 10, maxStdoutBytes: 4096, maxStderrBytes: 4096))
    try #require(merged.exitCode == 1)
    if includeOrdinaryChanges {
      try write("staged\n", "ordinary.txt", in: workspace)
      try await git(["add", "ordinary.txt"], workspace)
      try write("unstaged\n", "ordinary.txt", in: workspace)
    }
    let result = try await snapshot(workspace)
    #expect(result.files.count == (includeOrdinaryChanges ? 2 : 1))
    #expect(
      result.files[0].changes.allSatisfy {
        $0.kind == .unmerged && $0.omission == .conflict && $0.additions == nil
          && $0.deletions == nil && $0.patch.text.isEmpty
      })
    if includeOrdinaryChanges {
      let ordinary = try #require(result.files.first { $0.path.rawValue == "ordinary.txt" })
      #expect(ordinary.staged?.additions == 1)
      #expect(ordinary.staged?.deletions == 1)
      #expect(ordinary.staged?.patch.text.contains("+staged") == true)
      #expect(ordinary.unstaged?.additions == 1)
      #expect(ordinary.unstaged?.deletions == 1)
      #expect(ordinary.unstaged?.patch.text.contains("+unstaged") == true)
    }
  }

  private func repository() throws -> Workspace {
    let workspace = Workspace(name: "Diff", rootURL: try scopedTemporaryDirectory())
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/git")
    process.arguments = ["-C", workspace.rootURL.path, "init", "-q"]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    return workspace
  }

  private func write(_ text: String, _ path: String, in workspace: Workspace) throws {
    let url = workspace.rootURL.appending(path: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
  }

  private func git(_ args: [String], _ workspace: Workspace) async throws {
    let result = try await DefaultCommandProcessRunner().run(
      .init(
        executableURL: URL(filePath: "/usr/bin/git"),
        arguments: ["-c", "core.fsmonitor=false", "-C", workspace.rootURL.path] + args,
        environment: ProcessInfo.processInfo.environment, workingDirectoryURL: workspace.rootURL,
        timeoutSeconds: 10, maxStdoutBytes: 4096, maxStderrBytes: 4096))
    try #require(result.exitCode == 0, "\(result.stderr)")
  }

  private func commit(_ workspace: Workspace) async throws {
    try await git(["add", "."], workspace)
    try await git(
      [
        "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "fixture",
      ], workspace)
  }

  private func snapshot(_ workspace: Workspace, path: String? = nil) async throws
    -> WorkspaceDiffSnapshot
  {
    let result = await WorkspaceDiffToolExecutor().run(
      .init(path: path), context: .init(workspace: workspace))
    guard case .workspaceDiff(.snapshot(let snapshot)) = result else {
      throw DiffTestError.failed(result.text)
    }
    return snapshot
  }

  private func request() -> ToolCallRequest {
    .validated(
      raw: .init(workspaceID: UUID(), sessionID: UUID(), toolName: .workspaceDiff, arguments: [:]),
      payload: .workspaceDiff(.init()))
  }

  private func rendered(_ snapshot: WorkspaceDiffSnapshot) throws -> (
    text: String, json: [String: Any]
  ) {
    let payload = ToolResultPayload.workspaceDiff(.snapshot(snapshot))
    let entry = try ModelFacingPromptRenderer.toolResultEntry(
      toolResult: .init(callID: UUID(), toolName: .workspaceDiff, payload: payload),
      request: request(), originalUserRequest: nil)
    let text = entry.frozenContent.content
    return (text, try jsonHeader(text))
  }

  private func jsonHeader(_ text: String) throws -> [String: Any] {
    let line = try #require(text.split(separator: "\n").dropFirst().first)
    return try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
  }
}

private enum DiffTestError: Error { case failed(String) }

enum DiffFailureMode: Sendable {
  case none, statFailure, statTruncation, duplicateStatistics, malformedStatus, patchFailure
}

private actor DiffRecordingRunner: CommandProcessRunning {
  let failure: DiffFailureMode
  var requests: [CommandProcessRequest] = []
  var active = 0
  var maximumActive = 0
  init(failure: DiffFailureMode = .none) { self.failure = failure }
  func run(_ request: CommandProcessRequest) async throws -> CommandProcessResult {
    requests.append(request)
    active += 1
    maximumActive = max(maximumActive, active)
    defer { active -= 1 }
    if failure == .malformedStatus && request.arguments.contains("status") {
      return .init(exitCode: 0, durationMs: 0, stdout: "invalid\0", stderr: "")
    }
    if failure == .statFailure && request.arguments.contains("--numstat")
      || failure == .patchFailure && request.arguments.contains("--patch")
    {
      return .init(exitCode: 2, durationMs: 0, stdout: "", stderr: "fixture failure")
    }
    if failure == .statTruncation && request.arguments.contains("--numstat") {
      return .init(
        exitCode: 0, durationMs: 0, stdout: "1\t1\ttracked.txt\0", stderr: "", stdoutOmittedBytes: 1
      )
    }
    if failure == .duplicateStatistics && request.arguments.contains("--numstat") {
      return .init(
        exitCode: 0, durationMs: 0,
        stdout: "1\t1\ttracked.txt\0" + "1\t1\ttracked.txt\0", stderr: "")
    }
    return try await DefaultCommandProcessRunner().run(request)
  }
}

private actor DiffSleepingRunner: CommandProcessRunning {
  var cancelled = false
  func run(_ request: CommandProcessRequest) async throws -> CommandProcessResult {
    do { try await Task.sleep(for: .seconds(60)) } catch {
      cancelled = true
      throw error
    }
    return .init(exitCode: 0, durationMs: 0, stdout: "", stderr: "")
  }
}
