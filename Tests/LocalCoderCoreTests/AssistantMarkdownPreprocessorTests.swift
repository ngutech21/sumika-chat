import Testing

@testable import LocalCoderCore

struct AssistantMarkdownPreprocessorTests {
  @Test
  func leavesPlainMarkdownUnchanged() {
    let content = "Here is **bold** text with `inline code`."

    #expect(AssistantMarkdownPreprocessor.renderableContent(for: content) == content)
  }

  @Test
  func leavesFencedCodeUnchanged() {
    let content = """
      ```swift
      let value = 42
      ```
      """

    #expect(AssistantMarkdownPreprocessor.renderableContent(for: content) == content)
  }

  @Test
  func wrapsUnfencedHTMLAsCodeBlock() {
    let content = """
      <!DOCTYPE html>
      <html>
      <body>Hello</body>
      </html>
      """

    #expect(
      AssistantMarkdownPreprocessor.renderableContent(for: content) == """
        ```html
        <!DOCTYPE html>
        <html>
        <body>Hello</body>
        </html>
        ```
        """
    )
  }

  @Test
  func wrapsValidJSONAsCodeBlock() {
    let content = """
      {
        "name": "local-coder"
      }
      """

    #expect(
      AssistantMarkdownPreprocessor.renderableContent(for: content) == """
        ```json
        {
          "name": "local-coder"
        }
        ```
        """
    )
  }

  @Test
  func wrapsRawShellScriptAsCodeBlock() {
    let content = """
      #!/bin/bash
      for i in {1..5}; do
        echo "RobotName$i"
      done
      """

    #expect(
      AssistantMarkdownPreprocessor.renderableContent(for: content) == """
        ```bash
        #!/bin/bash
        for i in {1..5}; do
          echo "RobotName$i"
        done
        ```
        """
    )
  }

  @Test
  func wrapsUnfencedCSSAsCodeBlock() {
    let content = """
      body {
        color: #87CEEB;
        margin: 0;
      }
      """

    #expect(
      AssistantMarkdownPreprocessor.renderableContent(for: content) == """
        ```css
        body {
          color: #87CEEB;
          margin: 0;
        }
        ```
        """
    )
  }
}
