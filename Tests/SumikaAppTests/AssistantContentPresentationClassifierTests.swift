import Testing

@testable import SumikaApp

struct AssistantContentClassifierTests {
  @Test
  func proseContainingTypeScriptKeywordPrefixRemainsMarkdown() {
    let content = "Tasks and resources are modeled as constraints."

    #expect(AssistantContentPresentationClassifier.classify(content) == .markdown)
  }

  @Test
  func validJSONObjectIsRawJSON() {
    let content = """
      {
        "name": "sumika"
      }
      """

    #expect(AssistantContentPresentationClassifier.classify(content) == .rawCode(.json))
  }

  @Test
  func validJSONArrayIsRawJSON() {
    let content = """
      [
        "sumika",
        "local"
      ]
      """

    #expect(AssistantContentPresentationClassifier.classify(content) == .rawCode(.json))
  }

  @Test
  func completeHTMLDocumentIsRawHTML() {
    let content = """
      <!DOCTYPE html>
      <html>
      <body>Hello</body>
      </html>
      """

    #expect(AssistantContentPresentationClassifier.classify(content) == .rawCode(.html))
  }

  @Test
  func shellShebangIsRawBash() {
    let content = """
      #!/usr/bin/env bash
      set -euo pipefail
      echo "ready"
      """

    #expect(AssistantContentPresentationClassifier.classify(content) == .rawCode(.bash))
  }

  @Test
  func pythonShebangIsRawPython() {
    let content = """
      #!/usr/bin/env python3
      print("ready")
      """

    #expect(AssistantContentPresentationClassifier.classify(content) == .rawCode(.python))
  }

  @Test
  func completeTypeScriptDeclarationIsRawTypeScript() {
    let content = """
      interface Size {
        width: number
        height: number
      }
      """

    #expect(AssistantContentPresentationClassifier.classify(content) == .rawCode(.typescript))
  }

  @Test
  func typedTypeScriptBindingIsRawTypeScript() {
    let content = "const width: number = 1280"

    #expect(AssistantContentPresentationClassifier.classify(content) == .rawCode(.typescript))
  }

  @Test
  func completePythonDefinitionIsRawPython() {
    let content = """
      def greet(name: str) -> str:
          return f"Hello, {name}"
      """

    #expect(AssistantContentPresentationClassifier.classify(content) == .rawCode(.python))
  }

  @Test
  func pythonImportAndStatementAreRawPython() {
    let content = """
      import json
      payload = json.loads(source)
      print(payload)
      """

    #expect(AssistantContentPresentationClassifier.classify(content) == .rawCode(.python))
  }

  @Test
  func completeCSSRuleIsRawCSS() {
    let content = """
      body {
        color: #87CEEB;
        margin: 0;
      }
      """

    #expect(AssistantContentPresentationClassifier.classify(content) == .rawCode(.css))
  }

  @Test
  func completeSingleLineCSSRuleIsRawCSS() {
    let content = "body { color: #87CEEB; margin: 0; }"

    #expect(AssistantContentPresentationClassifier.classify(content) == .rawCode(.css))
  }

  @Test
  func shellControlStructureIsRawBash() {
    let content = """
      for file in *.swift; do
        echo "$file"
      done
      """

    #expect(AssistantContentPresentationClassifier.classify(content) == .rawCode(.bash))
  }

  @Test
  func shellAssignmentAndCommandAreRawBash() {
    let content = """
      target=Sumika
      printf '%s\\n' "$target"
      """

    #expect(AssistantContentPresentationClassifier.classify(content) == .rawCode(.bash))
  }

  @Test
  func markdownStructureOverridesEmbeddedTypeScriptSignals() {
    let content = """
      ## Protocol

      - Example:
        interface Size {
          width: number
        }
      """

    #expect(AssistantContentPresentationClassifier.classify(content) == .markdown)
  }

  @Test(
    arguments: [
      "This approach satisfies the requirement.",
      "One design concern remains.\n\ntype safety matters here.",
      "Run this after reviewing the diff:\n\ngit status",
      "The CSS declaration `color: red;` changes the foreground.",
      "color: red;",
      "Protocol value: `{ width: number }`.",
      "Tasks and resources are modeled as constraints.",
      "config satisfies Options",
      "value as const",
      "const config = defaults satisfies Options",
      "const config = defaults as const",
      "<div>Hello</div>",
      "const width = 1280",
      "print(\"ready\")",
      "git status",
      "cd Sources",
      "just test",
      "$ git status",
    ])
  func isolatedCodeLikeTextRemainsMarkdown(_ content: String) {
    #expect(AssistantContentPresentationClassifier.classify(content) == .markdown)
  }

  @Test(
    arguments: [
      """
      ### Protocol

      const width: number = 1280
      """,
      """
      | Field | Shape |
      | --- | --- |
      | width | `{ width: number }` |
      """,
      """
      1. Example
      2. `const width: number = 1280`
      """,
      """
      - Example
      - `const width: number = 1280`
      """,
      """
      > Example: `const width: number = 1280`
      """,
      """
      Introduction

      ---

      const width: number = 1280
      """,
    ])
  func structuredMarkdownOverridesCodeSignals(_ content: String) {
    #expect(AssistantContentPresentationClassifier.classify(content) == .markdown)
  }

  @Test(arguments: [2, 3, 4, 5, 6])
  func markdownHeadingLevelsOverrideCodeSignals(_ level: Int) {
    let content = """
      \(String(repeating: "#", count: level)) Protocol

      const width: number = 1280
      """

    #expect(AssistantContentPresentationClassifier.classify(content) == .markdown)
  }
}
