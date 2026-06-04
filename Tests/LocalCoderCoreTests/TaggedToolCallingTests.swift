import Foundation
import Testing

@testable import LocalCoderCore

struct TaggedToolCallingTests {
  @Test
  func registryContainsPromptToolsAndCanonicalLookup() throws {
    let registry = ToolExecutorRegistry.readOnly.toolRegistry

    #expect(
      registry.tools.map(\.name) == [.readFile, .showFile, .listFiles, .globFiles, .searchFiles])
    #expect(registry.definition(canonicalizing: "Read")?.name == .readFile)
    #expect(registry.definition(canonicalizing: "READ")?.name == .readFile)
    #expect(registry.definition(canonicalizing: "READ-FILE")?.name == .readFile)
    #expect(registry.definition(canonicalizing: "read-file")?.name == .readFile)
    #expect(registry.definition(canonicalizing: "read file")?.name == .readFile)
    #expect(registry.definition(canonicalizing: "show")?.name == .showFile)
    #expect(registry.definition(canonicalizing: "show-file")?.name == .showFile)
    #expect(registry.definition(canonicalizing: "glob-files")?.name == .globFiles)
    #expect(registry.definition(canonicalizing: "search files")?.name == .searchFiles)
    #expect(registry.definition(canonicalizing: "run_command") == nil)
  }

  @Test
  func promptRendererUsesCompactToolSignaturesAndGlobalExamples() {
    let prompt = TaggedToolPromptRenderer().renderToolInstructions(
      registry: ToolExecutorRegistry.readOnly.toolRegistry,
      payloadDelimiter: "LC_PAYLOAD_TEST"
    )

    #expect(prompt.contains(#"Emit exactly one <action name="tool_name">...</action>, then stop."#))
    #expect(prompt.contains("Use workspace-relative paths."))
    #expect(
      prompt.contains("- read_file(path, offset?, limit?): Read workspace file lines into context.")
    )
    #expect(
      prompt.contains(
        "- show_file(path, offset?, limit?): Display workspace file lines directly to the user."))
    #expect(prompt.contains("- list_files(path?): List files in a workspace directory."))
    #expect(prompt.contains("- glob_files(pattern, path?): Find workspace files by glob."))
    #expect(
      prompt.contains("- search_files(pattern, path?, include?): Search workspace text files."))
    #expect(
      prompt.contains(
        #"For content, old_text, and new_text, use delimiter="LC_PAYLOAD_TEST""#))
    #expect(prompt.contains("LC_PAYLOAD_TEST"))
    #expect(prompt.contains(#"<action name="read_file">"#))
    #expect(prompt.contains("<path>Sources/App.swift</path>"))
    #expect(prompt.contains("<content delimiter=\"LC_PAYLOAD_TEST\">"))
    #expect(prompt.contains("raw text"))
    #expect(!prompt.contains("Tool: read_file"))
    #expect(!prompt.contains("Description:"))
    #expect(!prompt.contains("Parameters:"))
    #expect(!prompt.contains("Sources/AppState.swift"))
    #expect(!prompt.contains("<pattern>**/*.swift</pattern>"))
    #expect(!prompt.contains("apply_patch"))
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
  func parserReturnsNoneForWhitespaceOnlyAssistantText() throws {
    let result = try TaggedToolCallParser().parse(
      " \n\t  ",
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
    #expect(request.rawText?.contains(#"<action name="READ-FILE">"#) == true)

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
  func parserParsesGlobAndSearchFilesActions() throws {
    let globRequest = try parsedRequest(
      """
      <action name="glob_files">
      <pattern>**/*.swift</pattern>
      </action>
      """
    )
    let searchRequest = try parsedRequest(
      """
      <action name="search_files">
      <pattern>ToolDefinition</pattern>
      <path>.</path>
      <include>*.swift</include>
      </action>
      """
    )

    #expect(globRequest.toolName == .globFiles)
    #expect(globRequest.arguments == ["pattern": .string("**/*.swift")])
    #expect(searchRequest.toolName == .searchFiles)
    #expect(
      searchRequest.arguments == [
        "pattern": .string("ToolDefinition"),
        "path": .string("."),
        "include": .string("*.swift"),
      ])
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
      <action name="write_file">
      <path>index.html</path>
      <content delimiter="LC_PAYLOAD_TEST">
      <div class="example">
        <p>Hello</p>
      </div>
      </content>
      {"literal": "</content>"}
      LC_PAYLOAD_TEST
      </content>
      </action>
      """
    )

    let expectedPayload = """
      <div class="example">
        <p>Hello</p>
      </div>
      </content>
      {"literal": "</content>"}
      """

    #expect(request.toolName == .writeFile)
    #expect(
      request.arguments == [
        "path": .string("index.html"),
        "content": .string(expectedPayload),
      ])
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
  func parserParsesContentPayloadWithIndentedClosingTagAfterDelimiter() throws {
    let request = try parsedRequest(
      """
      <action name="write_file">
        <path>index.html</path>
        <content delimiter="LC_PAYLOAD_TEST">
      <!DOCTYPE html>
      <html>
      <body>
        <h1>Hello, world!</h1>
      </body>
      </html>
      LC_PAYLOAD_TEST
        </content>
      </action>
      """
    )

    let expectedPayload = """
      <!DOCTYPE html>
      <html>
      <body>
        <h1>Hello, world!</h1>
      </body>
      </html>
      """

    #expect(request.toolName == .writeFile)
    #expect(
      request.arguments == [
        "path": .string("index.html"),
        "content": .string(expectedPayload),
      ])
  }

  @Test
  func parserParsesEditFileHeredocPayloads() throws {
    let request = try parsedRequest(
      """
      <action name="edit_file">
      <path>Sources/App.swift</path>
      <old_text delimiter="LC_PAYLOAD_TEST">
      func title() -> String {
        "Old"
      }
      LC_PAYLOAD_TEST
      </old_text>
      <new_text delimiter="LC_PAYLOAD_TEST">
      func title() -> String {
        "New"
      }
      LC_PAYLOAD_TEST
      </new_text>
      </action>
      """
    )

    let expectedOldText = """
      func title() -> String {
        "Old"
      }
      """
    let expectedNewText = """
      func title() -> String {
        "New"
      }
      """

    #expect(request.toolName == .editFile)
    #expect(
      request.arguments == [
        "path": .string("Sources/App.swift"),
        "old_text": .string(expectedOldText),
        "new_text": .string(expectedNewText),
      ])
  }

  @Test
  func parserParsesEditFilePayloadsWhenModelOmitsClosingDelimiterLines() throws {
    let request = try parsedRequest(
      """
      <action name="edit_file">
      <path>Sources/index.html</path>
      <old_text delimiter="LC_PAYLOAD_TEST">
      <html>
      <body>
      <h1>foo bar</h1>
      </body>
      </html>
      </old_text>
      <new_text delimiter="LC_PAYLOAD_TEST">
      <html>
      <body>
      <h1>foo bar</h1>
      <table>
      <tr><td>Column 1</td><td>Column 2</td><td>Column 3</td></tr>
      </table>
      </body>
      </html>
      </new_text>
      </action>
      """
    )

    let expectedOldText = """
      <html>
      <body>
      <h1>foo bar</h1>
      </body>
      </html>
      """
    let expectedNewText = """
      <html>
      <body>
      <h1>foo bar</h1>
      <table>
      <tr><td>Column 1</td><td>Column 2</td><td>Column 3</td></tr>
      </table>
      </body>
      </html>
      """

    #expect(request.toolName == .editFile)
    #expect(
      request.arguments == [
        "path": .string("Sources/index.html"),
        "old_text": .string(expectedOldText),
        "new_text": .string(expectedNewText),
      ])
  }

  @Test
  func parserParsesEditFilePairedPayloadsInAnyOrder() throws {
    let request = try parsedRequest(
      """
      <action name="edit_file">
      <new_text><html><title>Hello World</title></html></new_text>
      <old_text><html><title>My Page</title></html></old_text>
      <path>Sources/App.html</path>
      </action>
      """
    )

    #expect(request.toolName == .editFile)
    #expect(
      request.arguments == [
        "path": .string("Sources/App.html"),
        "old_text": .string("<html><title>My Page</title></html>"),
        "new_text": .string("<html><title>Hello World</title></html>"),
      ])
  }

  @Test
  func parserAcceptsCRLFDelimiterLines() throws {
    let content =
      "<action name=\"write_file\">\r\n<path>notes.txt</path>\r\n<content delimiter=\"LC_PAYLOAD_TEST\">\r\nline 1\r\nLC_PAYLOAD_TEST\r\n</content>\r\n</action>"

    let request = try parsedRequest(content)

    #expect(request.arguments == ["path": .string("notes.txt"), "content": .string("line 1")])
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

    #expect(throws: TaggedToolCallParseError.unclosedAction) {
      _ = try TaggedToolCallParser().parse(
        #"<action name="read_file">"# + "\n   ",
        workspaceID: UUID(),
        sessionID: UUID(),
        createdAt: Date()
      )
    }
  }

  @Test
  func parserRejectsEmptyDelimiters() {
    #expect(throws: TaggedToolCallParseError.emptyDelimiter("content")) {
      _ = try TaggedToolCallParser().parse(
        """
        <action name="write_file">
        <path>notes.txt</path>
        <content delimiter="">
        raw content
        </content>
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
  ) throws -> RawToolCallRequest {
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
