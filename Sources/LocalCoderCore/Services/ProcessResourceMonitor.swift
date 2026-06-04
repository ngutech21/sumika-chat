#if canImport(Darwin)
import Darwin
#endif
import Foundation

public protocol ProcessResourceMonitoring: Sendable {
  func currentUsage() async -> ProcessResourceUsage?
}

public actor ProcessResourceMonitor: ProcessResourceMonitoring {
  private var previousSample: ProcessResourceSample?

  public init() {}

  public func currentUsage() async -> ProcessResourceUsage? {
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
