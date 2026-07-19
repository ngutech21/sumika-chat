import Testing

@testable import DataModelGenerator

struct DataModelCollectorTests {
  @Test
  func collectorFindsPublicModelsStoredPropertiesAndEnumCases() throws {
    let source = """
      import Foundation

      /// Session state used by tests.
      public struct ChatSessionState: Equatable {
        public var turns: [ChatTurn]
        public var activeTurn: ChatTurn.ID?
        public var computed: String { "value" }
        private var hidden: HiddenModel
      }

      public enum ChatTurnItem {
        case user(UserTurnMessage)
        case toolResult(payload: ToolResultPayload, preview: ToolResultProjection?)
        case ignored
      }

      public protocol ChatTurnRendering {
        public var item: ChatTurnItem { get }
      }

      public typealias ToolCallArguments = [String: ToolArgumentValue]

      struct HiddenModel {
        public var value: String
      }
      """

    let models = try DataModelCollector().collect(source: source, sourcePath: "Fixture.swift")

    #expect(
      models.map(\.name).sorted() == [
        "ChatSessionState",
        "ChatTurnItem",
        "ChatTurnRendering",
        "ToolCallArguments",
      ])

    let session = try #require(models.first { $0.name == "ChatSessionState" })
    #expect(session.summary == "Session state used by tests.")
    #expect(
      session.properties == [
        DataModelProperty(name: "turns", type: "[ChatTurn]", isStored: true),
        DataModelProperty(name: "activeTurn", type: "ChatTurn.ID?", isStored: true),
      ])

    let payload = try #require(models.first { $0.name == "ChatTurnItem" })
    #expect(
      payload.cases == [
        DataModelCase(
          name: "user",
          associatedValues: [DataModelAssociatedValue(type: "UserTurnMessage")]
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
      "ChatTurn",
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
      referencedModelTypes(in: "ChatTurn.ID?", knownTypes: knownTypes) == ["ChatTurn"]
    )
  }
}
