import Foundation
import SwiftParser
import SwiftSyntax

public struct DataModelCollector: Sendable {
  public init() {}

  public func collect(source: String, sourcePath: String) throws -> [DataModelDeclaration] {
    let sourceFile = Parser.parse(source: source)
    let visitor = DeclarationVisitor(sourcePath: sourcePath)
    visitor.walk(sourceFile)
    return visitor.declarations
  }
}

private final class DeclarationVisitor: SyntaxVisitor {
  private let sourcePath: String
  fileprivate var declarations: [DataModelDeclaration] = []

  init(sourcePath: String) {
    self.sourcePath = sourcePath
    super.init(viewMode: .sourceAccurate)
  }

  override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
    guard node.modifiers.isPublic else {
      return .skipChildren
    }

    declarations.append(
      DataModelDeclaration(
        name: node.name.text,
        kind: .struct,
        conformances: node.inheritanceClause.modelTypeNames,
        summary: docSummary(from: node.leadingTrivia),
        properties: publicProperties(in: node.memberBlock),
        sourcePath: sourcePath
      )
    )
    return .skipChildren
  }

  override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
    guard node.modifiers.isPublic else {
      return .skipChildren
    }

    declarations.append(
      DataModelDeclaration(
        name: node.name.text,
        kind: .enum,
        conformances: node.inheritanceClause.modelTypeNames,
        summary: docSummary(from: node.leadingTrivia),
        properties: publicProperties(in: node.memberBlock),
        cases: enumCases(in: node.memberBlock),
        sourcePath: sourcePath
      )
    )
    return .skipChildren
  }

  override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
    guard node.modifiers.isPublic else {
      return .skipChildren
    }

    declarations.append(
      DataModelDeclaration(
        name: node.name.text,
        kind: .protocol,
        conformances: node.inheritanceClause.modelTypeNames,
        summary: docSummary(from: node.leadingTrivia),
        properties: publicProperties(in: node.memberBlock),
        sourcePath: sourcePath
      )
    )
    return .skipChildren
  }

  override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
    guard node.modifiers.isPublic else {
      return .skipChildren
    }

    declarations.append(
      DataModelDeclaration(
        name: node.name.text,
        kind: .typealias,
        summary: docSummary(from: node.leadingTrivia),
        aliasedType: normalizedType(node.initializer.value.description),
        sourcePath: sourcePath
      )
    )
    return .skipChildren
  }

  private func publicProperties(in memberBlock: MemberBlockSyntax) -> [DataModelProperty] {
    memberBlock.members.flatMap { member -> [DataModelProperty] in
      guard let variable = member.decl.as(VariableDeclSyntax.self),
        variable.modifiers.isPublic
      else {
        return []
      }

      return variable.bindings.compactMap { binding in
        guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self),
          let type = binding.typeAnnotation?.type.description
        else {
          return nil
        }

        return DataModelProperty(
          name: identifier.identifier.text,
          type: normalizedType(type),
          isStored: binding.accessorBlock == nil
        )
      }
      .filter(\.isStored)
    }
  }

  private func enumCases(in memberBlock: MemberBlockSyntax) -> [DataModelCase] {
    memberBlock.members.flatMap { member -> [DataModelCase] in
      guard let enumCase = member.decl.as(EnumCaseDeclSyntax.self) else {
        return []
      }

      return enumCase.elements.map { element in
        DataModelCase(
          name: element.name.text,
          associatedValues: associatedValues(from: element.parameterClause)
        )
      }
    }
  }

  private func associatedValues(
    from clause: EnumCaseParameterClauseSyntax?
  ) -> [DataModelAssociatedValue] {
    guard let clause else {
      return []
    }

    return clause.parameters.map { parameter in
      let firstName = parameter.firstName?.text
      let secondName = parameter.secondName?.text
      let candidateLabels: [String?] = [firstName, secondName]
      var label: String?
      for value in candidateLabels {
        guard let value, value != "_" else {
          continue
        }
        label = value
        break
      }

      return DataModelAssociatedValue(
        label: label,
        type: normalizedType(parameter.type.description)
      )
    }
  }
}

extension DeclModifierListSyntax {
  fileprivate var isPublic: Bool {
    contains { modifier in
      modifier.name.text == "public"
    }
  }
}

extension InheritanceClauseSyntax? {
  fileprivate var modelTypeNames: [String] {
    guard let self else {
      return []
    }

    return self.inheritedTypes
      .map { normalizedType($0.type.description) }
      .sorted()
  }
}

private func docSummary(from trivia: Trivia) -> String? {
  let lines = trivia.description
    .split(separator: "\n", omittingEmptySubsequences: false)
    .compactMap { rawLine -> String? in
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard line.hasPrefix("///") else {
        return nil
      }
      return line.dropFirst(3).trimmingCharacters(in: .whitespaces)
    }

  let summary = lines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
  return summary.isEmpty ? nil : summary
}

public func normalizedType(_ rawType: String) -> String {
  rawType
    .replacingOccurrences(of: "\n", with: " ")
    .split(whereSeparator: \.isWhitespace)
    .joined(separator: " ")
    .trimmingCharacters(in: .whitespacesAndNewlines)
}
