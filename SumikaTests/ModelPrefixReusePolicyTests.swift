import Foundation
import SumikaCore
import Testing

struct ModelPrefixReusePolicyTests {
  @Test
  func chatModelConfigurationDefaultsPrefixReuseToDisabled() {
    let configuration = ChatModelConfiguration(
      localModelDirectory: URL(filePath: "/tmp/model", directoryHint: .isDirectory)
    )

    #expect(configuration.prefixReusePolicy == .disabled)
  }

  @Test
  func chatModelConfigurationCarriesExplicitPrefixReusePolicy() {
    let configuration = ChatModelConfiguration(
      localModelDirectory: URL(filePath: "/tmp/model", directoryHint: .isDirectory),
      prefixReusePolicy: .cacheOnly
    )

    #expect(configuration.prefixReusePolicy == .cacheOnly)
  }
}
