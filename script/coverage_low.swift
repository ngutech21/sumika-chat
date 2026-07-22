#!/usr/bin/env swift

import Foundation

struct CoverageMetric: Decodable {
  let count: Int
  let covered: Int
}

struct CoverageSummary: Decodable {
  let lines: CoverageMetric
}

struct LLVMFileCoverage: Decodable {
  let filename: String
  let summary: CoverageSummary
}

struct LLVMExport: Decodable {
  struct Payload: Decodable {
    let files: [LLVMFileCoverage]
  }

  let data: [Payload]
}

struct LocalCoverageFile {
  let path: String
  let coveredLines: Int
  let executableLines: Int

  var lineCoverage: Double {
    guard executableLines > 0 else {
      return 0
    }
    return Double(coveredLines) / Double(executableLines)
  }
}

func usage() -> Never {
  fputs(
    "usage: coverage_low.swift <swiftpm-coverage.json> (--summary | --threshold 80)\n",
    stderr
  )
  exit(2)
}

func percent(_ value: Double) -> String {
  String(format: "%.1f%%", value * 100)
}

func localRelativePath(_ path: String, repoRoot: URL) -> String? {
  let rootPath = repoRoot.standardizedFileURL.path(percentEncoded: false) + "/"
  let absolutePath = URL(filePath: path).standardizedFileURL.path(percentEncoded: false)
  guard absolutePath.hasPrefix(rootPath) else {
    return nil
  }
  let relativePath = String(absolutePath.dropFirst(rootPath.count))
  guard
    relativePath.hasPrefix("sumika/")
      || relativePath.hasPrefix("Sources/")
      || relativePath.hasPrefix("Tests/")
  else {
    return nil
  }
  return relativePath
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let jsonReport = arguments.first else {
  usage()
}

enum ReportMode {
  case summary
  case below(threshold: Double)
}

let options = Array(arguments.dropFirst())
let mode: ReportMode
if options == ["--summary"] {
  mode = .summary
} else if options.count == 2, options[0] == "--threshold" {
  guard let threshold = Double(options[1]) else {
    usage()
  }
  mode = .below(threshold: threshold)
} else {
  usage()
}

let repoRoot = URL(filePath: FileManager.default.currentDirectoryPath)
let data = try Data(contentsOf: URL(filePath: jsonReport))
let report = try JSONDecoder().decode(LLVMExport.self, from: data)
let entries = report.data
  .flatMap(\.files)
  .compactMap { file -> LocalCoverageFile? in
    guard
      let relativePath = localRelativePath(file.filename, repoRoot: repoRoot),
      file.summary.lines.count > 0
    else {
      return nil
    }
    return LocalCoverageFile(
      path: relativePath,
      coveredLines: file.summary.lines.covered,
      executableLines: file.summary.lines.count
    )
  }
  .sorted { lhs, rhs in
    if lhs.lineCoverage == rhs.lineCoverage {
      return lhs.path < rhs.path
    }
    return lhs.lineCoverage < rhs.lineCoverage
  }

switch mode {
case .summary:
  let coveredLines = entries.reduce(0) { $0 + $1.coveredLines }
  let executableLines = entries.reduce(0) { $0 + $1.executableLines }
  let lineCoverage = executableLines == 0 ? 0 : Double(coveredLines) / Double(executableLines)
  print("Local line coverage: \(percent(lineCoverage)) (\(coveredLines)/\(executableLines))")
  for entry in entries.sorted(by: { $0.path < $1.path }) {
    let paddedCoverage = percent(entry.lineCoverage).leftPadding(toLength: 6)
    print("\(paddedCoverage)  \(entry.coveredLines)/\(entry.executableLines)  \(entry.path)")
  }
case .below(let threshold):
  let thresholdRatio = threshold / 100
  let lowEntries = entries.filter { $0.lineCoverage < thresholdRatio }
  print("Local coverage below \(String(format: "%g", threshold))%")
  if lowEntries.isEmpty {
    print("No local files below threshold.")
    exit(0)
  }
  for entry in lowEntries {
    print(
      "\n\(entry.path)  \(percent(entry.lineCoverage)) "
        + "(\(entry.coveredLines)/\(entry.executableLines))"
    )
  }
  print(
    "\n\(lowEntries.count) local files have coverage below "
      + "\(String(format: "%g", threshold))%."
  )
}

extension String {
  func leftPadding(toLength length: Int) -> String {
    guard count < length else {
      return self
    }
    return String(repeating: " ", count: length - count) + self
  }
}
