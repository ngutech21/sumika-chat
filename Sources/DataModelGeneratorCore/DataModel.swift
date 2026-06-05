import Foundation

public struct DataModelDocument: Equatable, Sendable {
  public var models: [DataModelDeclaration]

  public init(models: [DataModelDeclaration]) {
    self.models = models
  }
}

public struct DataModelDeclaration: Equatable, Sendable {
  public enum Kind: String, Equatable, Sendable {
    case `struct`
    case `enum`
    case `protocol`
    case `typealias`
  }

  public var name: String
  public var kind: Kind
  public var conformances: [String]
  public var summary: String?
  public var properties: [DataModelProperty]
  public var cases: [DataModelCase]
  public var aliasedType: String?
  public var sourcePath: String

  public init(
    name: String,
    kind: Kind,
    conformances: [String] = [],
    summary: String? = nil,
    properties: [DataModelProperty] = [],
    cases: [DataModelCase] = [],
    aliasedType: String? = nil,
    sourcePath: String
  ) {
    self.name = name
    self.kind = kind
    self.conformances = conformances
    self.summary = summary
    self.properties = properties
    self.cases = cases
    self.aliasedType = aliasedType
    self.sourcePath = sourcePath
  }
}

public struct DataModelProperty: Equatable, Sendable {
  public var name: String
  public var type: String
  public var isStored: Bool

  public init(name: String, type: String, isStored: Bool) {
    self.name = name
    self.type = type
    self.isStored = isStored
  }
}

public struct DataModelCase: Equatable, Sendable {
  public var name: String
  public var associatedValues: [DataModelAssociatedValue]

  public init(name: String, associatedValues: [DataModelAssociatedValue] = []) {
    self.name = name
    self.associatedValues = associatedValues
  }
}

public struct DataModelAssociatedValue: Equatable, Sendable {
  public var label: String?
  public var type: String

  public init(label: String? = nil, type: String) {
    self.label = label
    self.type = type
  }
}
