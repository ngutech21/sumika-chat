import Foundation
import Testing

@testable import local_coder

struct TaggedToolCallingTests {
  @Test
  func registryContainsPromptToolsAndCanonicalLookup() throws {
    let registry = ToolExecutorRegistry.readOnly.toolRegistry

    #expect(registry.tools.map(\.name) == [.readFile, .listFiles])
    #expect(registry.definition(canonicalizing: "READ-FILE")?.name == .readFile)
    #expect(registry.definition(canonicalizing: "read-file")?.name == .readFile)
    #expect(registry.definition(canonicalizing: "read file")?.name == .readFile)
    #expect(registry.definition(canonicalizing: "run_command") == nil)
  }

  @Test
  func promptRendererIncludesToolsExamplesAndDelimiterRules() {
    let prompt = TaggedToolPromptRenderer().renderToolInstructions(
      registry: ToolExecutorRegistry.readOnly.toolRegistry,
      payloadDelimiter: "LC_PAYLOAD_TEST"
    )

    #expect(prompt.contains("read_file"))
    #expect(prompt.contains("list_files"))
    #expect(prompt.contains("Read a text file inside the active workspace."))
    #expect(prompt.contains("<path>Sources/AppState.swift</path>"))
    #expect(prompt.contains("LC_PAYLOAD_TEST"))
    #expect(prompt.contains("Emit one complete <action> block and then stop."))
    #expect(prompt.contains("XML-inspired, but it is not XML"))
    #expect(prompt.contains("on its own line with no spaces"))
  }

  @Test
  func parserReturnsNoneForAssistantTextWithoutAction() throws {
    let result = try TaggedToolCallParser().parse(
      "I can explain the code without calling a tool.",
      workspaceID: UUID(),
      sessionID: UUID(),
      createdAt: Date(timeIntervalSince1970: 1)
    )

    #expect(result == .none)
  }

  @Test
  func parserParsesReadFileAction() throws {
    let workspaceID = UUID()
    let sessionID = UUID()
    let createdAt = Date(timeIntervalSince1970: 42)

    let request = try parsedRequest(
      """
      <action name="READ-FILE">
      <path>
        Sources/AppState.swift
      </path>
      </action>
      """,
      workspaceID: workspaceID,
      sessionID: sessionID,
      createdAt: createdAt
    )

    #expect(request.workspaceID == workspaceID)
    #expect(request.sessionID == sessionID)
    #expect(request.createdAt == createdAt)
    #expect(request.toolName == .readFile)
    #expect(request.arguments == ["path": .string("Sources/AppState.swift")])

    let modelMessage = try parsedOutput(
      """
      <action name="READ-FILE">
      <path>
        Sources/AppState.swift
      </path>
      </action>
      """,
      workspaceID: workspaceID,
      sessionID: sessionID,
      createdAt: createdAt
    ).modelMessage
    #expect(modelMessage.toolName == .readFile)
    #expect(
      modelMessage.arguments == [
        ToolCallModelArgument(name: "path", value: "Sources/AppState.swift")
      ])
  }

  @Test
  func parserParsesListFilesWithOptionalPath() throws {
    let request = try parsedRequest(
      """
      <action name="list_files">
      <path>.</path>
      </action>
      """
    )

    #expect(request.toolName == .listFiles)
    #expect(request.arguments == ["path": .string(".")])
  }

  @Test
  func parserAllowsUnknownToolNamesAsCanonicalRequests() throws {
    let request = try parsedRequest(
      """
      <action name="Shell-Exec">
      <path>.</path>
      </action>
      """
    )

    #expect(request.toolName == ToolName(canonicalizing: "shell_exec"))
    #expect(request.arguments == ["path": .string(".")])
  }

  @Test
  func parserParsesHeredocPayloadWithoutInterpretingTags() throws {
    let request = try parsedRequest(
      """
      <action name="apply_patch">
      <patch delimiter="LC_PAYLOAD_TEST">
      <div class="example">
        <p>Hello</p>
      </div>
      </patch>
      {"literal": "</patch>"}
      LC_PAYLOAD_TEST
      </patch>
      </action>
      """
    )

    let expectedPayload = """
      <div class="example">
        <p>Hello</p>
      </div>
      </patch>
      {"literal": "</patch>"}
      """

    #expect(request.toolName == .applyPatch)
    #expect(request.arguments == ["patch": .string(expectedPayload)])
  }

  @Test
  func parserParsesContentPayloadWhenModelOmitsClosingDelimiterLine() throws {
    let request = try parsedRequest(
      """
      <action name="write_file">
      <path>movies.html</path>
      <content delimiter="LC_PAYLOAD_TEST">
      <!DOCTYPE html>
      <html>
      <body>
      <table>
        <tr><td>The Lion King</td><td>Roger Allers</td><td>1994</td></tr>
      </table>
      </body>
      </html>
      </content>
      </action>
      """
    )

    let expectedPayload = """
      <!DOCTYPE html>
      <html>
      <body>
      <table>
        <tr><td>The Lion King</td><td>Roger Allers</td><td>1994</td></tr>
      </table>
      </body>
      </html>
      """

    #expect(request.toolName == .writeFile)
    #expect(
      request.arguments == [
        "path": .string("movies.html"),
        "content": .string(expectedPayload),
      ])
  }

  @Test
  func parserAcceptsCRLFDelimiterLines() throws {
    let content =
      "<action name=\"apply_patch\">\r\n<patch delimiter=\"LC_PAYLOAD_TEST\">\r\nline 1\r\nLC_PAYLOAD_TEST\r\n</patch>\r\n</action>"

    let request = try parsedRequest(content)

    #expect(request.arguments == ["patch": .string("line 1")])
  }

  @Test
  func parserRejectsMultipleActions() {
    #expect(throws: TaggedToolCallParseError.multipleActions) {
      _ = try TaggedToolCallParser().parse(
        """
        <action name="read_file">
        <path>a.swift</path>
        </action>
        <action name="read_file">
        <path>b.swift</path>
        </action>
        """,
        workspaceID: UUID(),
        sessionID: UUID(),
        createdAt: Date()
      )
    }
  }

  @Test
  func parserRejectsExtraneousContentAroundAction() {
    #expect(throws: TaggedToolCallParseError.extraneousContent) {
      _ = try TaggedToolCallParser().parse(
        """
        I will read the file.
        <action name="read_file">
        <path>a.swift</path>
        </action>
        """,
        workspaceID: UUID(),
        sessionID: UUID(),
        createdAt: Date()
      )
    }

    #expect(throws: TaggedToolCallParseError.extraneousContent) {
      _ = try TaggedToolCallParser().parse(
        """
        <action name="read_file">
        <path>a.swift</path>
        </action>
        Done.
        """,
        workspaceID: UUID(),
        sessionID: UUID(),
        createdAt: Date()
      )
    }
  }

  @Test
  func parserRejectsMissingAndEmptyActionNames() {
    #expect(throws: TaggedToolCallParseError.missingActionName) {
      _ = try TaggedToolCallParser().parse(
        "<action><path>a.swift</path></action>",
        workspaceID: UUID(),
        sessionID: UUID(),
        createdAt: Date()
      )
    }

    #expect(throws: TaggedToolCallParseError.emptyActionName) {
      _ = try TaggedToolCallParser().parse(
        #"<action name="   "><path>a.swift</path></action>"#,
        workspaceID: UUID(),
        sessionID: UUID(),
        createdAt: Date()
      )
    }
  }

  @Test
  func parserRejectsDuplicateParameters() {
    #expect(throws: TaggedToolCallParseError.duplicateParameter("path")) {
      _ = try TaggedToolCallParser().parse(
        """
        <action name="read_file">
        <path>a.swift</path>
        <path>b.swift</path>
        </action>
        """,
        workspaceID: UUID(),
        sessionID: UUID(),
        createdAt: Date()
      )
    }
  }

  @Test
  func parserRejectsMalformedTagsAndUnclosedActions() {
    #expect(throws: TaggedToolCallParseError.malformedTag) {
      _ = try TaggedToolCallParser().parse(
        #"<action name="read_file"><path value</path></action>"#,
        workspaceID: UUID(),
        sessionID: UUID(),
        createdAt: Date()
      )
    }

    #expect(throws: TaggedToolCallParseError.unclosedAction) {
      _ = try TaggedToolCallParser().parse(
        #"<action name="read_file"><path>a.swift</path>"#,
        workspaceID: UUID(),
        sessionID: UUID(),
        createdAt: Date()
      )
    }
  }

  @Test
  func parserRejectsMissingEmptyAndNonExactDelimiters() {
    #expect(throws: TaggedToolCallParseError.missingDelimiter("patch")) {
      _ = try TaggedToolCallParser().parse(
        """
        <action name="apply_patch">
        <patch>raw patch</patch>
        </action>
        """,
        workspaceID: UUID(),
        sessionID: UUID(),
        createdAt: Date()
      )
    }

    #expect(throws: TaggedToolCallParseError.emptyDelimiter("patch")) {
      _ = try TaggedToolCallParser().parse(
        """
        <action name="apply_patch">
        <patch delimiter="">
        raw patch
        </patch>
        </action>
        """,
        workspaceID: UUID(),
        sessionID: UUID(),
        createdAt: Date()
      )
    }

    #expect(throws: TaggedToolCallParseError.delimiterNotFound("LC_PAYLOAD_TEST")) {
      _ = try TaggedToolCallParser().parse(
        """
        <action name="apply_patch">
        <patch delimiter="LC_PAYLOAD_TEST">
        raw patch
         LC_PAYLOAD_TEST
        </patch>
        </action>
        """,
        workspaceID: UUID(),
        sessionID: UUID(),
        createdAt: Date()
      )
    }
  }

  private func parsedRequest(
    _ text: String,
    workspaceID: UUID = UUID(),
    sessionID: UUID = UUID(),
    createdAt: Date = Date(timeIntervalSince1970: 1)
  ) throws -> ToolCallRequest {
    try parsedOutput(
      text,
      workspaceID: workspaceID,
      sessionID: sessionID,
      createdAt: createdAt
    ).request
  }

  private func parsedOutput(
    _ text: String,
    workspaceID: UUID = UUID(),
    sessionID: UUID = UUID(),
    createdAt: Date = Date(timeIntervalSince1970: 1)
  ) throws -> ToolCallParseOutput {
    let result = try TaggedToolCallParser().parse(
      text,
      workspaceID: workspaceID,
      sessionID: sessionID,
      createdAt: createdAt
    )

    guard case .toolCall(let output) = result else {
      Issue.record("Expected a parsed tool call")
      throw TestFailure()
    }

    return output
  }
}

private struct TestFailure: Error {}
