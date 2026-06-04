import Darwin
import XCTest

final class LocalCoderUITests: XCTestCase {
  private let modelID = "gemma3-27b"
  private static let testRunTraceBasename =
    "\(traceTimestamp())-\(UUID().uuidString)-gemma3-27b-ui-test.jsonl"

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
    try sendPrompt(
      "Reply with one short sentence for a local UI smoke test.",
      in: application
    )
    waitForCompletedTurn(in: application)
    let promptRows = try waitForTraceRows(
      in: fixture.traceURL,
      afterOffset: promptTraceOffset,
      interactionMode: "chat",
      timeout: 60
    )

    XCTAssertTrue(promptRows.containsKind("gemma_request"))
    XCTAssertTrue(promptRows.containsKind("gemma_response"))
    XCTAssertTrue(promptRows.containsKind("turn_trace"))
    XCTAssertTrue(promptRows.containsInteractionMode("chat"))
  }

  @MainActor
  func testChatThenInspectModeCanUseWorkspaceContextWithoutEditingFiles() throws {
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
      readme: "Inspect mode workspace\n",
      files: ["table.html": html]
    )
    let application = try launchApp(fixture: fixture)
    defer {
      application.terminate()
    }

    try loadSelectedModel(in: application)
    try selectChatMode(in: application)
    let chatTraceOffset = fileSize(at: fixture.traceURL)
    try sendPrompt(
      "Reply with one short sentence confirming chat mode is working.", in: application)
    waitForCompletedTurn(in: application)
    let chatRows = try waitForTraceRows(
      in: fixture.traceURL,
      afterOffset: chatTraceOffset,
      interactionMode: "chat",
      timeout: 60
    )

    try selectInspectMode(in: application)
    let inspectTraceOffset = fileSize(at: fixture.traceURL)
    try sendPrompt(
      """
      Inspect table.html. Tell me the minimal CSS change to make the table background color \
      lightblue. Do not edit files.
      """,
      in: application
    )
    waitForCompletedTurn(in: application, timeout: 420)
    let inspectRows = try waitForTraceRows(
      in: fixture.traceURL,
      afterOffset: inspectTraceOffset,
      interactionMode: "inspect",
      timeout: 420
    )

    let htmlAfterInspect = try String(
      contentsOf: fixture.workspaceURL.appending(path: "table.html", directoryHint: .notDirectory),
      encoding: .utf8
    )
    XCTAssertEqual(htmlAfterInspect, html)

    XCTAssertTrue(chatRows.containsKind("gemma_request"))
    XCTAssertTrue(chatRows.containsKind("gemma_response"))
    XCTAssertTrue(chatRows.containsKind("turn_trace"))
    XCTAssertTrue(chatRows.containsInteractionMode("chat"))
    XCTAssertTrue(inspectRows.containsKind("gemma_request"))
    XCTAssertTrue(inspectRows.containsKind("gemma_response"))
    XCTAssertTrue(inspectRows.containsKind("turn_trace"))
    XCTAssertTrue(inspectRows.containsInteractionMode("inspect"))
  }

  private func launchFixture(
    readme: String,
    files: [String: String] = [:]
  ) throws -> LaunchFixture {
    let modelDirectory = modelCacheDirectory(modelID: modelID)
    let configURL = modelDirectory.appending(path: "config.json", directoryHint: .notDirectory)
    guard FileManager.default.fileExists(atPath: configURL.path(percentEncoded: false)) else {
      throw XCTSkip("Gemma 3 27B is not installed at \(modelDirectory.path(percentEncoded: false))")
    }

    let storageRoot = FileManager.default.temporaryDirectory.appending(
      path: "local-coder-ui-test-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    let workspaceURL = storageRoot.appending(path: "workspace", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
    try readme.write(
      to: workspaceURL.appending(path: "README.md", directoryHint: .notDirectory),
      atomically: true,
      encoding: .utf8
    )
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
    chooseGemma27BIfPickerIsAvailable(in: application)
    let messageField = application.textFields["message-field"]
    let loadButton = application.buttons["load-model-button"]
    XCTAssertTrue(loadButton.waitForExistence(timeout: 30))
    XCTAssertTrue(
      loadButton.isEnabled, "Load must be enabled for the preinstalled Gemma 3 27B cache.")
    loadButton.click()

    XCTAssertTrue(
      waitUntil(timeout: 600) {
        messageField.exists && messageField.isEnabled
      },
      "Gemma 3 27B did not become ready before the UI-test timeout."
    )
  }

  @MainActor
  private func chooseGemma27BIfPickerIsAvailable(in application: XCUIApplication) {
    let picker = application.descendants(matching: .any)["chat.modelPicker"]
    guard picker.waitForExistence(timeout: 5), picker.isEnabled else {
      return
    }

    picker.click()
    let modelItem = application.menuItems["Gemma 3 27B"]
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
  private func selectInspectMode(in application: XCUIApplication) throws {
    try selectMode("inspect", title: "Inspect", in: application)
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
  private func sendPrompt(_ prompt: String, in application: XCUIApplication) throws {
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
  }

  @MainActor
  private func waitForCompletedTurn(
    in application: XCUIApplication,
    timeout: TimeInterval = 300
  ) {
    let assistantMessage = application.descendants(matching: .any)["chat.assistantMessage"]
    let generationMetrics = application.descendants(matching: .any)["chat.generationMetrics"]
    XCTAssertTrue(
      waitUntil(timeout: timeout) {
        assistantMessage.exists || generationMetrics.exists
      },
      "No completed assistant turn appeared before the UI-test timeout."
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

  private func waitForTraceRows(
    in traceURL: URL,
    afterOffset offset: UInt64,
    interactionMode: String? = nil,
    timeout: TimeInterval
  ) throws -> [TraceRow] {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      let rows = try traceRows(in: traceURL, afterOffset: offset)
      if rows.containsRequiredTraceKinds()
        && interactionMode.map(rows.containsInteractionMode(_:)) != false
      {
        return rows
      }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.25))
    }

    let rows = try traceRows(in: traceURL, afterOffset: offset)
    XCTFail(
      """
      Timed out waiting for complete trace rows after offset \(offset). \
      Required kinds: gemma_request, gemma_response, turn_trace. \
      Expected mode: \(interactionMode ?? "any"). \
      Found kinds: \(rows.map(\.kind).sorted().joined(separator: ", ")).
      """
    )
    throw LocalCoderUITestError.traceRowsTimedOut(interactionMode)
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
      return TraceRow(kind: kind, interactionMode: object["interactionMode"] as? String)
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
    appContainerApplicationSupport()
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

    return appContainerApplicationSupport()
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

  private func appContainerApplicationSupport() -> URL {
    Self.appContainerApplicationSupport()
  }

  private static func appContainerApplicationSupport() -> URL {
    realUserHomeDirectory()
      .appending(path: "Library", directoryHint: .isDirectory)
      .appending(path: "Containers", directoryHint: .isDirectory)
      .appending(path: "ngutech21.local-coder", directoryHint: .isDirectory)
      .appending(path: "Data", directoryHint: .isDirectory)
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

private struct TraceRow {
  let kind: String
  let interactionMode: String?
}

private enum LocalCoderUITestError: Error {
  case modeSelectionFailed(String)
  case traceRowsTimedOut(String?)
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
}
