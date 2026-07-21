import Testing

@testable import SumikaCore

struct CodeLanguageTests {
  @Test
  func normalizesFenceLanguageAliases() {
    #expect(CodeLanguage(fenceLanguage: "json") == .json)
    #expect(CodeLanguage(fenceLanguage: "py") == .python)
    #expect(CodeLanguage(fenceLanguage: "python3") == .python)
    #expect(CodeLanguage(fenceLanguage: "sh") == .bash)
    #expect(CodeLanguage(fenceLanguage: "shell") == .bash)
    #expect(CodeLanguage(fenceLanguage: "zsh") == .bash)
    #expect(CodeLanguage(fenceLanguage: "css") == .css)
    #expect(CodeLanguage(fenceLanguage: "scss") == nil)
    #expect(CodeLanguage(fenceLanguage: "html") == .html)
    #expect(CodeLanguage(fenceLanguage: "htm") == .html)
    #expect(CodeLanguage(fenceLanguage: "js") == .javascript)
    #expect(CodeLanguage(fenceLanguage: "mjs") == .javascript)
    #expect(CodeLanguage(fenceLanguage: "cjs") == .javascript)
    #expect(CodeLanguage(fenceLanguage: "ts") == .typescript)
    #expect(CodeLanguage(fenceLanguage: "tsx") == nil)
    #expect(CodeLanguage(fenceLanguage: "swift") == nil)
  }

  @Test
  func normalizesFilePathExtensions() {
    #expect(CodeLanguage(filePath: "hello.py") == .python)
    #expect(CodeLanguage(filePath: "scripts/deploy.sh") == .bash)
    #expect(CodeLanguage(filePath: "style.css") == .css)
    #expect(CodeLanguage(filePath: "styles/app.scss") == nil)
    #expect(CodeLanguage(filePath: "site/index.html") == .html)
    #expect(CodeLanguage(filePath: "site/partial.htm") == .html)
    #expect(CodeLanguage(filePath: "package.json") == .json)
    #expect(CodeLanguage(filePath: "src/app.js") == .javascript)
    #expect(CodeLanguage(filePath: "src/app.ts") == .typescript)
    #expect(CodeLanguage(filePath: "src/app.tsx") == nil)
    #expect(CodeLanguage(filePath: "README.md") == nil)
  }
}
