import Testing

@testable import SumikaCore

struct ProcessResourceUsageTests {
  @Test
  func formatsMemoryUsingBinaryUnits() {
    #expect(ProcessResourceUsage.formatMemory(bytes: 512) == "512 B")
    #expect(ProcessResourceUsage.formatMemory(bytes: 1_572_864) == "1.5 MB")
    #expect(ProcessResourceUsage.formatMemory(bytes: 1_610_612_736) == "1.5 GB")
  }

  @Test
  func formatsCpuPercentWithoutDecimals() {
    let usage = ProcessResourceUsage(memoryBytes: 512, cpuPercent: 42.4)

    #expect(usage.cpuSummary == "42%")
  }

  @Test
  func calculatesCpuPercentFromCpuAndWallTimeDeltas() {
    let previous = ProcessResourceSample(cpuTime: 10, wallTime: 100)
    let current = ProcessResourceSample(cpuTime: 11.5, wallTime: 101)

    #expect(ProcessResourceCalculator.cpuPercent(previous: previous, current: current) == 150)
  }

  @Test
  func clampsInvalidCpuSamplesToZero() {
    let previous = ProcessResourceSample(cpuTime: 10, wallTime: 100)

    #expect(
      ProcessResourceCalculator.cpuPercent(
        previous: previous,
        current: ProcessResourceSample(cpuTime: 9, wallTime: 101)
      ) == 0)
    #expect(
      ProcessResourceCalculator.cpuPercent(
        previous: previous,
        current: ProcessResourceSample(cpuTime: 11, wallTime: 100)
      ) == 0)
  }
}
