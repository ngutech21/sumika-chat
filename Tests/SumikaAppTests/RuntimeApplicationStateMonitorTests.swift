import SumikaCore
import Testing

@testable import SumikaApp

struct RuntimeApplicationStateMonitorTests {
  @Test
  func mainWindowVisibilityUsesStablePrecedence() {
    #expect(
      RuntimeApplicationStateMonitor.mainWindowVisibility(
        isMiniaturized: true,
        isVisible: false,
        isOccluded: true
      ) == .minimized
    )
    #expect(
      RuntimeApplicationStateMonitor.mainWindowVisibility(
        isMiniaturized: false,
        isVisible: false,
        isOccluded: true
      ) == .notVisible
    )
    #expect(
      RuntimeApplicationStateMonitor.mainWindowVisibility(
        isMiniaturized: false,
        isVisible: true,
        isOccluded: true
      ) == .occluded
    )
    #expect(
      RuntimeApplicationStateMonitor.mainWindowVisibility(
        isMiniaturized: false,
        isVisible: true,
        isOccluded: false
      ) == .visible
    )
  }
}
