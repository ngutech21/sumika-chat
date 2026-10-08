struct DataModelDocument: Equatable, Sendable {
  var models: [DataModelDeclaration]
}

struct DataModelDeclaration: Equatable, Sendable {
  enum Kind: String, Equatable, Sendable {
    case `struct`
    case `enum`
    case `protocol`
    case `typealias`
  }

  var name: String
  var kind: Kind
  var conformances: [String] = []
  var summary: String?
  var properties: [DataModelProperty] = []
  var cases: [DataModelCase] = []
  var aliasedType: String?
  var sourcePath: String
}

struct DataModelProperty: Equatable, Sendable {
  var name: String
  var type: String
  var isStored: Bool
}

struct DataModelCase: Equatable, Sendable {
  var name: String
  var associatedValues: [DataModelAssociatedValue] = []
}

struct DataModelAssociatedValue: Equatable, Sendable {
  var label: String?
  var type: String
}
