import Foundation

package struct ProcessResourceUsage: Equatable, Sendable {
  package let memoryBytes: UInt64
  package let cpuPercent: Double

  package var memorySummary: String {
    Self.formatMemory(bytes: memoryBytes)
  }

  package var cpuSummary: String {
    String(format: "%.0f%%", cpuPercent)
  }

  package static func formatMemory(bytes: UInt64) -> String {
    guard bytes >= 1024 else {
      return "\(bytes) B"
    }

    let units = ["KB", "MB", "GB", "TB"]
    var value = Double(bytes) / 1024
    var unitIndex = 0

    while value >= 1024, unitIndex < units.count - 1 {
      value /= 1024
      unitIndex += 1
    }

    return String(format: "%.1f %@", value, units[unitIndex])
  }
}

package struct ProcessResourceSample: Equatable, Sendable {
  package let cpuTime: TimeInterval
  package let wallTime: TimeInterval
}

package enum ProcessResourceCalculator {
  package static func cpuPercent(
    previous: ProcessResourceSample,
    current: ProcessResourceSample
  ) -> Double {
    let cpuDelta = current.cpuTime - previous.cpuTime
    let wallDelta = current.wallTime - previous.wallTime

    guard cpuDelta >= 0, wallDelta > 0 else {
      return 0
    }

    return cpuDelta / wallDelta * 100
  }
}
