import Foundation
import Testing

@testable import SumikaCore

/// Golden-fixture tests pinning the persisted workspace-library schema.
///
/// The checked-in legacy fixture remains the v0 migration contract. The v1
/// fixtures pin the split manifest and session envelopes byte for byte.
/// any schema change fails these tests until the change is made intentional —
/// either by adding a default for a new field or by regenerating the fixture
/// with `SUMIKA_REGENERATE_FIXTURES=1 xcrun swift test`.
struct WorkspaceLibrarySchemaTests {
  @Test
  func goldenFixtureEncodesByteIdentically() throws {
    let encoded = try Self.encodeLikeWorkspaceStore(WorkspaceLibraryGoldenFixture.makeLibrary())

    if ProcessInfo.processInfo.environment["SUMIKA_REGENERATE_FIXTURES"] == "1" {
      try encoded.write(to: Self.fixtureURL)
      return
    }

    let fixture = try Self.loadFixture()
    #expect(
      encoded == fixture,
      """
      Persisted workspace-library schema changed. If the change is intentional, \
      regenerate the fixture with SUMIKA_REGENERATE_FIXTURES=1 xcrun swift test \
      and review the fixture diff.
      """
    )
  }

  @Test
  func goldenFixtureDecodesExactlyWithoutDrops() throws {
    let diagnostics = DecodeDiagnostics()
    let decoded = try Self.makeDecoder(diagnostics: diagnostics).decode(
      WorkspaceLibrary.self,
      from: Self.loadFixture()
    )

    #expect(decoded == WorkspaceLibraryGoldenFixture.makeLibrary())
    #expect(diagnostics.droppedElements.isEmpty)
  }

  @Test
  func versionOneGoldenFixturesEncodeByteIdentically() throws {
    let library = WorkspaceLibraryGoldenFixture.makeLibrary()
    let manifestData = try WorkspacePersistenceCoding.makeEncoder().encode(
      WorkspaceLibraryManifest(
        library: library,
        updatedAt: Date(timeIntervalSinceReferenceDate: 9_500)
      )
    )
    let session = try #require(library.workspaces.first?.sessions.first)
    let sessionData = try WorkspacePersistenceCoding.makeEncoder().encode(
      WorkspaceSessionDocument(session: session)
    )

    if ProcessInfo.processInfo.environment["SUMIKA_REGENERATE_FIXTURES"] == "1" {
      try manifestData.write(to: Self.manifestV1FixtureURL)
      try sessionData.write(to: Self.sessionV1FixtureURL)
      return
    }

    let expectedManifestData = try Data(contentsOf: Self.manifestV1FixtureURL)
    let expectedSessionData = try Data(contentsOf: Self.sessionV1FixtureURL)
    #expect(manifestData == expectedManifestData)
    #expect(sessionData == expectedSessionData)
  }

  @Test
  func versionOneGoldenFixturesDecodeExactlyWithoutDrops() throws {
    guard ProcessInfo.processInfo.environment["SUMIKA_REGENERATE_FIXTURES"] != "1" else {
      return
    }
    let library = WorkspaceLibraryGoldenFixture.makeLibrary()
    let manifestDiagnostics = DecodeDiagnostics()
    let manifest = try WorkspacePersistenceCoding.makeDecoder(
      diagnostics: manifestDiagnostics
    ).decode(
      WorkspaceLibraryManifest.self,
      from: Data(contentsOf: Self.manifestV1FixtureURL)
    )
    let sessionDiagnostics = DecodeDiagnostics()
    let sessionDocument = try WorkspacePersistenceCoding.makeDecoder(
      diagnostics: sessionDiagnostics
    ).decode(
      WorkspaceSessionDocument.self,
      from: Data(contentsOf: Self.sessionV1FixtureURL)
    )

    #expect(
      manifest
        == WorkspaceLibraryManifest(
          library: library,
          updatedAt: Date(timeIntervalSinceReferenceDate: 9_500)
        )
    )
    #expect(sessionDocument == WorkspaceSessionDocument(session: library.workspaces[0].sessions[0]))
    #expect(manifestDiagnostics.droppedElements.isEmpty)
    #expect(sessionDiagnostics.droppedElements.isEmpty)
  }

  /// The fixture must keep exercising every persisted union so renames in any
  /// of them fail the byte comparison instead of slipping through untested.
  @Test
  func goldenFixtureCoversAllItemKindsAndToolStates() throws {
    let json = try #require(String(data: Self.loadFixture(), encoding: .utf8))

    for itemKind in ["userMessage", "assistantThinking", "assistantMessage", "tool"] {
      #expect(json.contains("\"kind\" : \"\(itemKind)\""), "missing item kind \(itemKind)")
    }
    for state in ["completed", "awaitingApproval", "denied", "failed", "cancelled"] {
      #expect(json.contains("\"kind\" : \"\(state)\""), "missing tool state \(state)")
    }
  }

  @Test
  func decodingToleratesUnknownFieldsEverywhere() throws {
    var object = try Self.fixtureJSONObject()
    object["futureLibraryField"] = "ignored"

    var workspaces = try #require(object["workspaces"] as? [[String: Any]])
    workspaces[0]["futureWorkspaceField"] = ["nested": true]

    var sessions = try #require(workspaces[0]["sessions"] as? [[String: Any]])
    sessions[0]["futureSessionField"] = 7

    var turns = try #require(sessions[0]["turns"] as? [[String: Any]])
    turns[0]["futureTurnField"] = "ignored"

    var items = try #require(turns[0]["items"] as? [[String: Any]])
    items[0]["futureItemField"] = "ignored"

    turns[0]["items"] = items
    sessions[0]["turns"] = turns
    workspaces[0]["sessions"] = sessions
    object["workspaces"] = workspaces

    let diagnostics = DecodeDiagnostics()
    let decoded = try Self.makeDecoder(diagnostics: diagnostics).decode(
      WorkspaceLibrary.self,
      from: JSONSerialization.data(withJSONObject: object)
    )

    #expect(decoded == WorkspaceLibraryGoldenFixture.makeLibrary())
    #expect(diagnostics.droppedElements.isEmpty)
  }

  @Test
  func unknownItemKindDropsOnlyThatItem() throws {
    var object = try Self.fixtureJSONObject()
    var workspaces = try #require(object["workspaces"] as? [[String: Any]])
    var sessions = try #require(workspaces[0]["sessions"] as? [[String: Any]])
    var turns = try #require(sessions[0]["turns"] as? [[String: Any]])
    var items = try #require(turns[0]["items"] as? [[String: Any]])
    items.append(["kind": "futureItemKind", "payload": ["value": 1]])
    turns[0]["items"] = items
    sessions[0]["turns"] = turns
    workspaces[0]["sessions"] = sessions
    object["workspaces"] = workspaces

    let diagnostics = DecodeDiagnostics()
    let decoded = try Self.makeDecoder(diagnostics: diagnostics).decode(
      WorkspaceLibrary.self,
      from: JSONSerialization.data(withJSONObject: object)
    )

    #expect(decoded == WorkspaceLibraryGoldenFixture.makeLibrary())
    #expect(diagnostics.droppedElements.count == 1)
  }

  @Test
  func unknownToolStateKindDropsOnlyThatRecord() throws {
    var object = try Self.fixtureJSONObject()
    var workspaces = try #require(object["workspaces"] as? [[String: Any]])
    var sessions = try #require(workspaces[0]["sessions"] as? [[String: Any]])
    let agentSessionIndex = try #require(
      sessions.firstIndex { $0["title"] as? String == "Agent Session" }
    )
    var turns = try #require(sessions[agentSessionIndex]["turns"] as? [[String: Any]])
    var items = try #require(turns[0]["items"] as? [[String: Any]])
    let originalItemCount = items.count
    let toolItemIndex = try #require(items.firstIndex { $0["kind"] as? String == "tool" })
    var toolItem = items[toolItemIndex]
    var payload = try #require(toolItem["payload"] as? [String: Any])
    var state = try #require(payload["state"] as? [String: Any])
    state["kind"] = "futureToolState"
    payload["state"] = state
    toolItem["payload"] = payload
    items[toolItemIndex] = toolItem
    turns[0]["items"] = items
    sessions[agentSessionIndex]["turns"] = turns
    workspaces[0]["sessions"] = sessions
    object["workspaces"] = workspaces

    let diagnostics = DecodeDiagnostics()
    let decoded = try Self.makeDecoder(diagnostics: diagnostics).decode(
      WorkspaceLibrary.self,
      from: JSONSerialization.data(withJSONObject: object)
    )

    let agentSession = try #require(
      decoded.workspaces.first?.sessions.first { $0.title == "Agent Session" }
    )
    #expect(agentSession.turns[0].items.count == originalItemCount - 1)
    #expect(
      !agentSession.turns[0].items.contains {
        $0.messageID == WorkspaceLibraryGoldenFixture.completedToolCallID
      }
    )
    #expect(diagnostics.droppedElements.count == 1)
  }

  /// The exact scenario the schema policy must survive: an old file that lacks
  /// a field newer code expects decodes with the documented default instead of
  /// dropping the containing element.
  @Test
  func missingNewFieldFallsBackToDefaultInsteadOfDroppingElement() throws {
    var object = try Self.fixtureJSONObject()
    var workspaces = try #require(object["workspaces"] as? [[String: Any]])
    var sessions = try #require(workspaces[0]["sessions"] as? [[String: Any]])
    let chatSessionIndex = try #require(
      sessions.firstIndex { $0["title"] as? String == "Chat Session" }
    )
    var turns = try #require(sessions[chatSessionIndex]["turns"] as? [[String: Any]])
    var items = try #require(turns[0]["items"] as? [[String: Any]])
    let messageIndex = try #require(
      items.firstIndex { $0["kind"] as? String == "assistantMessage" }
    )
    var messageItem = items[messageIndex]
    var payload = try #require(messageItem["payload"] as? [String: Any])
    payload.removeValue(forKey: "modelProjectionPolicy")
    messageItem["payload"] = payload
    items[messageIndex] = messageItem
    turns[0]["items"] = items
    sessions[chatSessionIndex]["turns"] = turns
    workspaces[0]["sessions"] = sessions
    object["workspaces"] = workspaces

    let diagnostics = DecodeDiagnostics()
    let decoded = try Self.makeDecoder(diagnostics: diagnostics).decode(
      WorkspaceLibrary.self,
      from: JSONSerialization.data(withJSONObject: object)
    )

    let chatSession = try #require(
      decoded.workspaces.first?.sessions.first { $0.title == "Chat Session" }
    )
    let assistantMessage = try #require(
      chatSession.turns[0].items.lazy.compactMap { item -> AssistantTurnMessage? in
        guard case .assistantMessage(let message) = item else {
          return nil
        }
        return message
      }.first
    )
    #expect(assistantMessage.modelProjectionPolicy == .visibleContent)
    #expect(diagnostics.droppedElements.isEmpty)
  }

  private static var fixtureURL: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "Fixtures", directoryHint: .isDirectory)
      .appending(path: "workspace-library-golden.json", directoryHint: .notDirectory)
  }

  private static var manifestV1FixtureURL: URL {
    fixtureDirectoryURL.appending(
      path: "workspace-manifest-v1-golden.json",
      directoryHint: .notDirectory
    )
  }

  private static var sessionV1FixtureURL: URL {
    fixtureDirectoryURL.appending(
      path: "workspace-session-v1-golden.json",
      directoryHint: .notDirectory
    )
  }

  private static var fixtureDirectoryURL: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "Fixtures", directoryHint: .isDirectory)
  }

  private static func loadFixture() throws -> Data {
    guard FileManager.default.fileExists(atPath: fixtureURL.path(percentEncoded: false)) else {
      Issue.record(
        "Golden fixture is missing. Generate it with SUMIKA_REGENERATE_FIXTURES=1 xcrun swift test"
      )
      throw CocoaError(.fileReadNoSuchFile)
    }
    return try Data(contentsOf: fixtureURL)
  }

  private static func fixtureJSONObject() throws -> [String: Any] {
    guard
      let object = try JSONSerialization.jsonObject(with: loadFixture()) as? [String: Any]
    else {
      throw CocoaError(.coderReadCorrupt)
    }
    return object
  }

  /// Matches WorkspaceStore's encoder so the fixture bytes represent exactly
  /// what the app writes to disk.
  private static func encodeLikeWorkspaceStore(_ library: WorkspaceLibrary) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(library)
  }

  private static func makeDecoder(diagnostics: DecodeDiagnostics) -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.userInfo[.decodeDiagnostics] = diagnostics
    return decoder
  }
}
