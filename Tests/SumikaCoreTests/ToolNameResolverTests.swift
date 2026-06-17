import Testing

@testable import SumikaCore

struct ToolNameResolverTests {
  private let resolver = ToolNameResolver()
  private let registry = ToolExecutorRegistry.codingAgent.toolRegistry

  @Test
  func resolvesExactToolName() {
    #expect(resolver.resolve("read_file", registry: registry) == .exact(.readFile))
  }

  @Test
  func repairsCaseAndSeparatorVariants() {
    #expect(
      resolver.resolve("READ_FILE", registry: registry)
        == .repaired(original: "READ_FILE", canonical: .readFile, method: .caseFold))
    #expect(
      resolver.resolve("Read_File", registry: registry)
        == .repaired(original: "Read_File", canonical: .readFile, method: .caseFold))
    #expect(
      resolver.resolve("read-file", registry: registry)
        == .repaired(original: "read-file", canonical: .readFile, method: .separator))
  }

  @Test
  func repairsCamelCaseVariants() {
    #expect(
      resolver.resolve("readFile", registry: registry)
        == .repaired(original: "readFile", canonical: .readFile, method: .camelCase))
  }

  @Test
  func doesNotGuessSemanticAliases() {
    #expect(resolver.resolve("run", registry: registry) == .unknown(original: "run"))
    #expect(resolver.resolve("write", registry: registry) == .unknown(original: "write"))
    #expect(resolver.resolve("edit", registry: registry) == .unknown(original: "edit"))
    #expect(resolver.resolve("search", registry: registry) == .unknown(original: "search"))
  }

}
