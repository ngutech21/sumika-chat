import Testing

@testable import SumikaApp

@Suite
struct AppUpdaterTests {
  @Test
  func releaseLaunchStartsUpdater() {
    #expect(
      AppLaunchConfiguration.shouldStartUpdater(
        environment: [:],
        isDebugBuild: false
      )
    )
  }

  @Test
  func debugLaunchDoesNotStartUpdater() {
    #expect(
      !AppLaunchConfiguration.shouldStartUpdater(
        environment: [:],
        isDebugBuild: true
      )
    )
  }

  @Test
  func uiTestLaunchDoesNotStartUpdater() {
    #expect(
      !AppLaunchConfiguration.shouldStartUpdater(
        environment: ["SUMIKA_UI_TEST_MODE": "1"],
        isDebugBuild: false
      )
    )
  }
}
