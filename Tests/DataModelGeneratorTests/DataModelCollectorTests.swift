import Testing

@testable import DataModelGeneratorCore

struct DataModelCollectorTests {
  @Test
  func collectorFindsPublicModelsStoredPropertiesAndEnumCases() throws {
    let source = """
      import Foundation

      /// Session state used by tests.
      public struct ChatSessionState: Equatable {
        public var messages: [ChatMessage]
        public var activeMessage: ChatMessage.ID?
        public var computed: String { "value" }
        private var hidden: HiddenModel
      }

      public enum ChatMessagePayload {
        case user(UserMessagePayload)
        case toolResult(payload: ToolResultPayload, preview: ToolResultProjection?)
        case ignored
      }

      public protocol ChatMessageRendering {
        public var message: ChatMessage { get }
      }

      public typealias ToolCallArguments = [String: ToolArgumentValue]

      struct HiddenModel {
        public var value: String
      }
      """

    let models = try DataModelCollector().collect(source: source, sourcePath: "Fixture.swift")

    #expect(
      models.map(\.name).sorted() == [
        "ChatMessagePayload",
        "ChatMessageRendering",
        "ChatSessionState",
        "ToolCallArguments",
      ])

    let session = try #require(models.first { $0.name == "ChatSessionState" })
    #expect(session.summary == "Session state used by tests.")
    #expect(
      session.properties == [
        DataModelProperty(name: "messages", type: "[ChatMessage]", isStored: true),
        DataModelProperty(name: "activeMessage", type: "ChatMessage.ID?", isStored: true),
      ])

    let payload = try #require(models.first { $0.name == "ChatMessagePayload" })
    #expect(
      payload.cases == [
        DataModelCase(
          name: "user",
          associatedValues: [DataModelAssociatedValue(type: "UserMessagePayload")]
        ),
        DataModelCase(
          name: "toolResult",
          associatedValues: [
            DataModelAssociatedValue(label: "payload", type: "ToolResultPayload"),
            DataModelAssociatedValue(label: "preview", type: "ToolResultProjection?"),
          ]
        ),
        DataModelCase(name: "ignored"),
      ])

    let alias = try #require(models.first { $0.name == "ToolCallArguments" })
    #expect(alias.aliasedType == "[String: ToolArgumentValue]")
  }

  @Test
  func referencedModelTypesNormalizesContainersAndQualifiedIDs() {
    let knownTypes: Set<String> = [
      "ChatMessage",
      "FocusedFileSnapshot",
      "WorkspaceRelativePath",
    ]

    #expect(
      referencedModelTypes(
        in: "[WorkspaceRelativePath: FocusedFileSnapshot]?",
        knownTypes: knownTypes
      ) == ["FocusedFileSnapshot", "WorkspaceRelativePath"]
    )
    #expect(
      referencedModelTypes(in: "ChatMessage.ID?", knownTypes: knownTypes) == ["ChatMessage"]
    )
  }
}
