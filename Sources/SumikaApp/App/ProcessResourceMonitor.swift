import Foundation
import Observation

#if canImport(Darwin)
  import Darwin
#endif

struct ProcessResourceUsage: Equatable, Sendable {
  let memoryBytes: UInt64
  let cpuPercent: Double

  var memorySummary: String {
    Self.formatMemory(bytes: memoryBytes)
  }

  var cpuSummary: String {
    String(format: "%.0f%%", cpuPercent)
  }

  static func formatMemory(bytes: UInt64) -> String {
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

struct ProcessResourceSample: Equatable, Sendable {
  let cpuTime: TimeInterval
  let wallTime: TimeInterval
}

enum ProcessResourceCalculator {
  nonisolated static func cpuPercent(
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

@MainActor
@Observable
final class ProcessResourceMonitor {
  private(set) var usage: ProcessResourceUsage?

  @ObservationIgnored private let sampler = ProcessResourceSampler()
  @ObservationIgnored private var monitoringTask: Task<Void, Never>?

  private static let samplingInterval: Duration = .seconds(5)
  private static let memoryPublishThresholdBytes: UInt64 = 16 * 1024 * 1024
  private static let cpuPublishThreshold = 1.0

  func start() {
    guard monitoringTask == nil else {
      return
    }

    let sampler = sampler
    monitoringTask = Task { [weak self] in
      while !Task.isCancelled {
        let usage = await sampler.currentUsage()
        self?.publish(usage)
        do {
          try await Task.sleep(for: Self.samplingInterval)
        } catch {
          return
        }
      }
    }
  }

  deinit {
    monitoringTask?.cancel()
  }

  private func publish(_ newUsage: ProcessResourceUsage?) {
    guard shouldPublish(newUsage) else {
      return
    }
    usage = newUsage
  }

  private func shouldPublish(_ newUsage: ProcessResourceUsage?) -> Bool {
    guard let usage else {
      return newUsage != nil
    }
    guard let newUsage else {
      return true
    }

    let memoryDelta =
      usage.memoryBytes > newUsage.memoryBytes
      ? usage.memoryBytes - newUsage.memoryBytes
      : newUsage.memoryBytes - usage.memoryBytes
    let cpuDelta = abs(usage.cpuPercent - newUsage.cpuPercent)

    return memoryDelta >= Self.memoryPublishThresholdBytes
      || cpuDelta >= Self.cpuPublishThreshold
  }
}

private actor ProcessResourceSampler {
  private var previousSample: ProcessResourceSample?

  func currentUsage() -> ProcessResourceUsage? {
    guard let memoryBytes = Self.currentMemoryBytes(),
      let currentSample = Self.currentSample()
    else {
      return nil
    }

    let cpuPercent =
      previousSample.map {
        ProcessResourceCalculator.cpuPercent(previous: $0, current: currentSample)
      } ?? 0
    previousSample = currentSample

    return ProcessResourceUsage(
      memoryBytes: memoryBytes,
      cpuPercent: cpuPercent
    )
  }

  private static func currentMemoryBytes() -> UInt64? {
    #if canImport(Darwin)
      var info = task_vm_info_data_t()
      var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
      )

      let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
          task_info(
            mach_task_self_,
            task_flavor_t(TASK_VM_INFO),
            reboundPointer,
            &count
          )
        }
      }

      guard result == KERN_SUCCESS else {
        return nil
      }

      return UInt64(info.phys_footprint)
    #else
      return nil
    #endif
  }

  private static func currentSample() -> ProcessResourceSample? {
    #if canImport(Darwin)
      var usage = rusage()
      guard getrusage(RUSAGE_SELF, &usage) == 0 else {
        return nil
      }

      return ProcessResourceSample(
        cpuTime: seconds(from: usage.ru_utime) + seconds(from: usage.ru_stime),
        wallTime: Date().timeIntervalSinceReferenceDate
      )
    #else
      return nil
    #endif
  }

  #if canImport(Darwin)
    private static func seconds(from time: timeval) -> TimeInterval {
      Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000
    }
  #endif
}
