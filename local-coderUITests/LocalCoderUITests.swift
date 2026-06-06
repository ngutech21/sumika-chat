import Darwin
import XCTest

final class LocalCoderUITests: XCTestCase {
  private let modelID = "gemma4-e4b"
  private static let testRunTraceBasename =
    "\(traceTimestamp())-\(UUID().uuidString)-gemma4-e4b-ui-test.jsonl"

  @MainActor
  func testSmokeLoadsSelectedModelAndCompletesFirstChatPrompt() throws {
    let fixture = try launchFixture(readme: "Smoke test workspace\n")
    let application = try launchApp(fixture: fixture)
    defer {
      application.terminate()
    }

    try loadSelectedModel(in: application)
    try selectChatMode(in: application)

    let promptTraceOffset = fileSize(at: fixture.traceURL)
    let promptBaseline = try sendPrompt(
      "Reply with one short sentence for a local UI smoke test.",
      in: application
    )
    waitForCompletedTurn(in: application, after: promptBaseline)
    let promptRows = try traceRows(
      in: fixture.traceURL,
      afterOffset: promptTraceOffset
    )

    recordTraceSummary(promptRows, expectedMode: "chat", label: "Smoke chat trace")
  }

  @MainActor
  func testChatThenAgentModeCanUseWorkspaceContextWithoutEditingFiles() throws {
    let html = """
      <!doctype html>
      <html>
      <head>
        <style>
          table { border-collapse: collapse; }
          td { padding: 4px; }
        </style>
      </head>
      <body>
        <table>
          <tr><td>Name</td><td>Status</td></tr>
          <tr><td>Local Coder</td><td>Testing</td></tr>
        </table>
      </body>
      </html>
      """
    let fixture = try launchFixture(
      readme: "Agent mode workspace\n",
      files: ["table.html": html]
    )
    let application = try launchApp(fixture: fixture)
    defer {
      application.terminate()
    }

    try loadSelectedModel(in: application)
    try selectChatMode(in: application)
    let chatTraceOffset = fileSize(at: fixture.traceURL)
    let chatBaseline = try sendPrompt(
      "Reply with one short sentence confirming chat mode is working.", in: application)
    waitForCompletedTurn(in: application, after: chatBaseline)
    let chatRows = try traceRows(
      in: fixture.traceURL,
      afterOffset: chatTraceOffset
    )

    try selectAgentMode(in: application)
    let agentTraceOffset = fileSize(at: fixture.traceURL)
    let agentBaseline = try sendPrompt(
      """
      Inspect table.html. Tell me the minimal CSS change to make the table background color \
      lightblue. Do not edit files.
      """,
      in: application
    )
    waitForCompletedTurn(in: application, after: agentBaseline, timeout: 420)
    let agentRows = try traceRows(
      in: fixture.traceURL,
      afterOffset: agentTraceOffset
    )

    let htmlAfterAgent = try String(
      contentsOf: fixture.workspaceURL.appending(path: "table.html", directoryHint: .notDirectory),
      encoding: .utf8
    )
    XCTAssertEqual(htmlAfterAgent, html)

    recordTraceSummary(chatRows, expectedMode: "chat", label: "Chat mode trace")
    recordTraceSummary(agentRows, expectedMode: "agent", label: "Agent mode trace")
  }

  @MainActor
  func testChatThenAgentListsFilesOnceAndShowsRequestedFile() throws {
    let robotsHTML = """
      <!DOCTYPE html>
      <html>
      <head>
      <title>Robots</title>
      <style>
      body {
        background-color: red;
      }
      </style>
      </head>
      <body>

      <h2>Robots</h2>

      <table border="1">
        <tr>
          <th>Name</th>
          <th>Type</th>
          <th>Power Source</th>
          <th>Speed</th>
          <th>Purpose</th>
        </tr>
        <tr>
          <td>Robot 1</td>
          <td>Humanoid</td>
          <td>Battery</td>
          <td>10 km/h</td>
          <td>Exploration</td>
        </tr>
      </table>

      </body>
      </html>
      """
    let fixture = try launchFixture(
      files: [
        "index.html": "<!doctype html>\n<title>Index</title>\n",
        "robots.html": robotsHTML,
      ]
    )
    let application = try launchApp(fixture: fixture)
    defer {
      application.terminate()
    }

    try loadSelectedModel(in: application)
    try selectChatMode(in: application)
    let chatTraceOffset = fileSize(at: fixture.traceURL)
    let chatBaseline = try sendPrompt("hey", in: application)
    waitForCompletedTurn(in: application, after: chatBaseline, timeout: 120)
    let chatRows = try traceRows(in: fixture.traceURL, afterOffset: chatTraceOffset)
    recordTraceSummary(chatRows, expectedMode: "chat", label: "List test chat trace")

    try selectAgentMode(in: application)
    let listTraceOffset = fileSize(at: fixture.traceURL)
    let listBaseline = try sendPrompt("list all files in the directory", in: application)
    waitForCompletedTurn(in: application, after: listBaseline, timeout: 420)
    let listRows = try traceRows(in: fixture.traceURL, afterOffset: listTraceOffset)
    recordTraceSummary(listRows, expectedMode: "agent", label: "List files trace")

    XCTAssertGreaterThanOrEqual(
      toolCallCount(in: application, named: "list_files", after: listBaseline), 1)

    let showFileTraceOffset = fileSize(at: fixture.traceURL)
    let showFileBaseline = try sendPrompt("show the contents of robots.html", in: application)
    waitForCompletedTurn(in: application, after: showFileBaseline, timeout: 420)
    let showFileRows = try traceRows(in: fixture.traceURL, afterOffset: showFileTraceOffset)
    recordTraceSummary(showFileRows, expectedMode: "agent", label: "Show file trace")

    XCTAssertGreaterThanOrEqual(
      toolCallCount(in: application, named: "show_file", after: showFileBaseline), 1)
  }

  @MainActor
  func testAgentReadFileFollowUpCompletesAndRecordsTrace() throws {
    let fixture = try launchFixture(
      readme: """
        Issue 44 ledger fixture.
        Second line.
        """
    )
    let application = try launchApp(fixture: fixture)
    defer {
      application.terminate()
    }

    try loadSelectedModel(in: application)
    try selectAgentMode(in: application)
    let traceOffset = fileSize(at: fixture.traceURL)
    let baseline = try sendPrompt(
      "Use the read_file tool with path README.md, offset 1, and limit 1. Then answer with that line only.",
      in: application
    )
    waitForCompletedTurn(in: application, after: baseline, timeout: 420)
    let rows = try traceRows(in: fixture.traceURL, afterOffset: traceOffset)
    recordTraceSummary(rows, expectedMode: "agent", label: "Read file cache trace")
  }

  @MainActor
  func testContextUsageRefreshWithLargeToolHistoryStaysResponsive() throws {
    let largeFile = (1...700)
      .map { line in
        "Performance fixture line \(line): local context usage should stay estimate-only."
      }
      .joined(separator: "\n")
    let fixture = try launchFixture(
      files: ["large-context.txt": largeFile]
    )
    let application = try launchApp(fixture: fixture)
    defer {
      application.terminate()
    }

    try loadSelectedModel(in: application)
    try selectAgentMode(in: application)
    let toolTraceOffset = fileSize(at: fixture.traceURL)
    let baseline = try sendPrompt(
      "Use the show_file tool with path large-context.txt. Then answer with one short sentence.",
      in: application
    )
    waitForCompletedTurn(in: application, after: baseline, timeout: 420)
    let toolRows = try traceRows(in: fixture.traceURL, afterOffset: toolTraceOffset)
    recordTraceSummary(toolRows, expectedMode: "agent", label: "Large tool history trace")

    let refreshTraceOffset = fileSize(at: fixture.traceURL)
    let refreshStartedAt = Date()
    try selectChatMode(in: application)
    try selectAgentMode(in: application)
    waitForGenerationIdle(in: application, timeout: 30)
    let refreshDurationMs = Date().timeIntervalSince(refreshStartedAt) * 1000
    let observationWindowMs = 5_000.0
    let observationDeadline = Date().addingTimeInterval(observationWindowMs / 1000)
    var refreshRows = try traceRows(in: fixture.traceURL, afterOffset: refreshTraceOffset)
    while refreshRows.isEmpty && Date() < observationDeadline {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.25))
      refreshRows = try traceRows(in: fixture.traceURL, afterOffset: refreshTraceOffset)
    }

    XCTAssertLessThan(refreshDurationMs, 2_000)
    recordTraceSummary(refreshRows, expectedMode: nil, label: "Mode refresh trace")
    XCTContext.runActivity(named: "Large context usage refresh performance") { activity in
      activity.add(
        XCTAttachment(
          string: """
            refreshDurationMs=\(String(format: "%.1f", refreshDurationMs))
            observationWindowMs=\(String(format: "%.1f", observationWindowMs))
            tokenize_context_usage_rows=\(refreshRows.tokenizeContextUsageCount)
            """
        ))
    }
  }

  private func launchFixture(
    readme: String? = nil,
    files: [String: String] = [:]
  ) throws -> LaunchFixture {
    let modelDirectory = modelCacheDirectory(modelID: modelID)
    let configURL = modelDirectory.appending(path: "config.json", directoryHint: .notDirectory)
    guard FileManager.default.fileExists(atPath: configURL.path(percentEncoded: false)) else {
      throw XCTSkip(
        "Gemma 4 E4B Experimental is not installed at \(modelDirectory.path(percentEncoded: false))"
      )
    }

    let storageRoot = FileManager.default.temporaryDirectory.appending(
      path: "local-coder-ui-test-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    let workspaceURL = storageRoot.appending(path: "workspace", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
    if let readme {
      try readme.write(
        to: workspaceURL.appending(path: "README.md", directoryHint: .notDirectory),
        atomically: true,
        encoding: .utf8
      )
    }
    for (path, contents) in files {
      let url = workspaceURL.appending(path: path, directoryHint: .notDirectory)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    let traceURL = traceFileURL()
    return LaunchFixture(
      storageRoot: storageRoot,
      workspaceURL: workspaceURL,
      traceURL: traceURL,
      traceOffset: fileSize(at: traceURL)
    )
  }

  @MainActor
  private func launchApp(fixture: LaunchFixture) throws -> XCUIApplication {
    let application = XCUIApplication()
    application.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
    application.launchEnvironment["LOCAL_CODER_UI_TEST_MODE"] = "1"
    application.launchEnvironment["LOCAL_CODER_UI_TEST_STORAGE_ROOT"] =
      fixture.storageRoot.path(percentEncoded: false)
    application.launchEnvironment["LOCAL_CODER_UI_TEST_WORKSPACE_PATH"] =
      fixture.workspaceURL.path(percentEncoded: false)
    application.launchEnvironment["LOCAL_CODER_UI_TEST_MODEL_ID"] = modelID
    application.launchEnvironment["LOCAL_CODER_DEBUG_TRACE"] = "1"
    application.launchEnvironment["LOCAL_CODER_DEBUG_TRACE_BASENAME"] =
      Self.testRunTraceBasename

    application.launch()
    XCTAssertTrue(application.textFields["message-field"].waitForExistence(timeout: 30))
    return application
  }

  @MainActor
  private func loadSelectedModel(in application: XCUIApplication) throws {
    chooseGemma4E4BIfPickerIsAvailable(in: application)
    let messageField = application.textFields["message-field"]
    let loadButton = application.buttons["load-model-button"]
    XCTAssertTrue(loadButton.waitForExistence(timeout: 30))
    XCTAssertTrue(
      loadButton.isEnabled,
      "Load must be enabled for the preinstalled Gemma 4 E4B Experimental cache.")
    loadButton.click()

    XCTAssertTrue(
      waitUntil(timeout: 600) {
        messageField.exists && messageField.isEnabled
      },
      "Gemma 4 E4B Experimental did not become ready before the UI-test timeout."
    )
  }

  @MainActor
  private func chooseGemma4E4BIfPickerIsAvailable(in application: XCUIApplication) {
    let picker = application.descendants(matching: .any)["chat.modelPicker"]
    guard picker.waitForExistence(timeout: 5), picker.isEnabled else {
      return
    }

    picker.click()
    let modelItem = application.menuItems["Gemma 4 E4B Experimental"]
    if modelItem.waitForExistence(timeout: 2) {
      modelItem.click()
    } else {
      application.typeKey(.escape, modifierFlags: [])
    }
  }

  @MainActor
  private func selectChatMode(in application: XCUIApplication) throws {
    try selectMode("chat", title: "Chat", in: application)
  }

  @MainActor
  private func selectAgentMode(in application: XCUIApplication) throws {
    try selectMode("agent", title: "Agent", in: application)
  }

  @MainActor
  private func selectMode(_ rawValue: String, title: String, in application: XCUIApplication) throws
  {
    let identifiedSegment = application.descendants(matching: .any)["chat.mode.\(rawValue)"]
    if waitUntil(
      timeout: 60,
      predicate: {
        identifiedSegment.exists && identifiedSegment.isEnabled
      })
    {
      identifiedSegment.click()
      return
    }

    let modePicker = application.segmentedControls["chat.modePicker"]
    if modePicker.waitForExistence(timeout: 5) {
      let button = modePicker.buttons[title]
      if button.waitForExistence(timeout: 2), button.isEnabled {
        button.click()
        return
      }
    }

    let fallbackButton = application.buttons[title]
    if fallbackButton.waitForExistence(timeout: 2), fallbackButton.isEnabled {
      fallbackButton.click()
      return
    }

    XCTFail("Could not select \(title) mode in the chat composer.")
    throw LocalCoderUITestError.modeSelectionFailed(title)
  }

  @MainActor
  private func sendPrompt(_ prompt: String, in application: XCUIApplication) throws
    -> UITurnBaseline
  {
    let baseline = UITurnBaseline.capture(in: application)
    let messageField = application.textFields["message-field"]
    XCTAssertTrue(
      waitUntil(timeout: 30) {
        messageField.exists && messageField.isEnabled
      }
    )
    messageField.click()
    messageField.typeText(prompt)

    let sendButton = application.buttons["send-button"]
    XCTAssertTrue(sendButton.waitForExistence(timeout: 10))
    XCTAssertTrue(sendButton.isEnabled)
    sendButton.click()
    return baseline
  }

  @MainActor
  private func waitForCompletedTurn(
    in application: XCUIApplication,
    after baseline: UITurnBaseline,
    timeout: TimeInterval = 300
  ) {
    XCTAssertTrue(
      waitUntil(timeout: timeout) {
        UITurnBaseline.capture(in: application).hasCompletedTurn(after: baseline)
      },
      "No completed assistant turn appeared before the UI-test timeout."
    )
    waitForGenerationIdle(in: application, timeout: timeout)
  }

  @MainActor
  private func toolCallCount(
    in application: XCUIApplication,
    named toolName: String,
    after baseline: UITurnBaseline
  ) -> Int {
    let toolCalls = application.descendants(matching: .any)
      .matching(identifier: "chat.toolCallMessage")
      .allElementsBoundByIndex
    guard toolCalls.count > baseline.toolCallCount else {
      return 0
    }
    return toolCalls[baseline.toolCallCount...].filter { element in
      element.matchesText(containing: toolName)
    }.count
  }

  @MainActor
  private func recordTraceSummary(
    _ rows: [TraceRow],
    expectedMode: String?,
    label: String
  ) {
    XCTContext.runActivity(named: label) { activity in
      activity.add(
        XCTAttachment(
          string: """
            expectedMode=\(expectedMode ?? "any")
            rows=\(rows.count)
            kinds=\(rows.map(\.kind).sorted().joined(separator: ", "))
            modes=\(Set(rows.compactMap(\.interactionMode)).sorted().joined(separator: ", "))
            toolNames=\(rows.compactMap(\.toolName).joined(separator: ", "))
            tokenize_context_usage_rows=\(rows.tokenizeContextUsageCount)
            contains_required_kinds=\(rows.containsRequiredTraceKinds())
            """
        ))
    }
  }

  @MainActor
  private func waitForGenerationIdle(
    in application: XCUIApplication,
    timeout: TimeInterval = 300
  ) {
    let messageField = application.textFields["message-field"]
    let cancelButton = application.buttons["cancel-generation-button"]
    XCTAssertTrue(
      waitUntil(timeout: timeout) {
        messageField.exists && messageField.isEnabled && !cancelButton.exists
      },
      "Generation did not become idle before the UI-test timeout."
    )
  }

  @MainActor
  private func waitUntil(timeout: TimeInterval, predicate: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if predicate() {
        return true
      }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.25))
    }
    return predicate()
  }

  private func traceRows(in traceURL: URL, afterOffset offset: UInt64) throws -> [TraceRow] {
    guard FileManager.default.fileExists(atPath: traceURL.path(percentEncoded: false)) else {
      return []
    }

    let handle = try FileHandle(forReadingFrom: traceURL)
    defer {
      try? handle.close()
    }
    try handle.seek(toOffset: offset)
    let data = try handle.readToEnd() ?? Data()
    guard let text = String(data: data, encoding: .utf8) else {
      return []
    }

    return text.split(separator: "\n").compactMap { line in
      guard
        let data = String(line).data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let kind = object["kind"] as? String
      else {
        return nil
      }
      return TraceRow(
        kind: kind,
        phase: object["phase"] as? String,
        toolName: object["toolName"] as? String,
        output: object["output"] as? String,
        interactionMode: object["interactionMode"] as? String,
        toolLoopIteration: object["toolLoopIteration"] as? Int,
        cacheMode: object["cacheMode"] as? String,
        cacheReason: object["cacheReason"] as? String
      )
    }
  }

  private func fileSize(at url: URL) -> UInt64 {
    guard
      let attributes = try? FileManager.default.attributesOfItem(
        atPath: url.path(percentEncoded: false)
      ),
      let size = attributes[.size] as? NSNumber
    else {
      return 0
    }
    return size.uint64Value
  }

  private func modelCacheDirectory(modelID: String) -> URL {
    appApplicationSupport()
      .appending(path: "local-coder", directoryHint: .isDirectory)
      .appending(path: "Models", directoryHint: .isDirectory)
      .appending(path: modelID, directoryHint: .isDirectory)
  }

  private func traceFileURL() -> URL {
    if let traceFile = ProcessInfo.processInfo.environment["LOCAL_CODER_DEBUG_TRACE_FILE"],
      !traceFile.isEmpty
    {
      return URL(filePath: traceFile, directoryHint: .notDirectory)
    }

    return appApplicationSupport()
      .appending(path: "local-coder", directoryHint: .isDirectory)
      .appending(path: "debug", directoryHint: .isDirectory)
      .appending(path: "traces", directoryHint: .isDirectory)
      .appending(path: Self.testRunTraceBasename, directoryHint: .notDirectory)
  }

  private static func traceTimestamp() -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd'T'HHmmss'Z'"
    return formatter.string(from: Date())
  }

  private func appApplicationSupport() -> URL {
    Self.appApplicationSupport()
  }

  private static func appApplicationSupport() -> URL {
    realUserHomeDirectory()
      .appending(path: "Library", directoryHint: .isDirectory)
      .appending(path: "Application Support", directoryHint: .isDirectory)
  }

  private func realUserHomeDirectory() -> URL {
    Self.realUserHomeDirectory()
  }

  private static func realUserHomeDirectory() -> URL {
    if let passwd = getpwuid(getuid()),
      let home = passwd.pointee.pw_dir
    {
      return URL(filePath: String(cString: home), directoryHint: .isDirectory)
    }
    return URL(filePath: "/Users/\(NSUserName())", directoryHint: .isDirectory)
  }
}

private struct LaunchFixture {
  let storageRoot: URL
  let workspaceURL: URL
  let traceURL: URL
  let traceOffset: UInt64
}

private struct UITurnBaseline {
  let assistantMessageCount: Int
  let generationMetricsCount: Int
  let toolCallCount: Int

  @MainActor
  static func capture(in application: XCUIApplication) -> UITurnBaseline {
    UITurnBaseline(
      assistantMessageCount: application.descendants(matching: .any)
        .matching(identifier: "chat.assistantMessage")
        .count,
      generationMetricsCount: application.descendants(matching: .any)
        .matching(identifier: "chat.generationMetrics")
        .count,
      toolCallCount: application.descendants(matching: .any)
        .matching(identifier: "chat.toolCallMessage")
        .count
    )
  }

  func hasCompletedTurn(after baseline: UITurnBaseline) -> Bool {
    assistantMessageCount > baseline.assistantMessageCount
      || generationMetricsCount > baseline.generationMetricsCount
  }
}

private struct TraceRow {
  let kind: String
  let phase: String?
  let toolName: String?
  let output: String?
  let interactionMode: String?
  let toolLoopIteration: Int?
  let cacheMode: String?
  let cacheReason: String?
}

private enum LocalCoderUITestError: Error {
  case modeSelectionFailed(String)
}

extension XCUIElement {
  fileprivate func matchesText(containing text: String) -> Bool {
    label.contains(text) || ((value as? String)?.contains(text) == true)
  }
}

extension Array where Element == TraceRow {
  fileprivate func containsRequiredTraceKinds() -> Bool {
    containsKind("gemma_request") && containsKind("gemma_response") && containsKind("turn_trace")
  }

  fileprivate func containsKind(_ kind: String) -> Bool {
    contains { $0.kind == kind }
  }

  fileprivate func containsInteractionMode(_ interactionMode: String) -> Bool {
    contains { $0.interactionMode == interactionMode }
  }

  fileprivate func toolExecutionCount(named toolName: String) -> Int {
    filter { row in
      row.kind == "turn_trace" && row.phase == "tool_execute" && row.toolName == toolName
    }.count
  }

  fileprivate func containsResponseOutput(containing text: String) -> Bool {
    contains { row in
      row.kind == "gemma_response" && row.output?.contains(text) == true
    }
  }

  fileprivate func containsRuntimeEvent(
    phase: String,
    toolLoopIteration: Int,
    cacheMode: String,
    cacheReason: String
  ) -> Bool {
    contains { row in
      row.kind == "turn_trace"
        && row.phase == phase
        && row.toolLoopIteration == toolLoopIteration
        && row.cacheMode == cacheMode
        && row.cacheReason == cacheReason
    }
  }

  fileprivate func containsToolLoopRuntimeCacheReason(_ cacheReason: String) -> Bool {
    contains { row in
      row.kind == "turn_trace"
        && row.phase?.hasPrefix("runtime_") == true
        && row.toolLoopIteration != nil
        && row.cacheReason == cacheReason
    }
  }

  fileprivate var tokenizeContextUsageCount: Int {
    filter { row in
      row.kind == "turn_trace" && row.phase == "tokenize_context_usage"
    }.count
  }
}
