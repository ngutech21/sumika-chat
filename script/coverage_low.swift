#!/usr/bin/env swift

import Foundation

struct CoverageFunction {
  let name: String
  let lineCoverage: Double
  let executableLines: Int
}

struct CoverageFile {
  let path: String
  let lineCoverage: Double
  let coveredLines: Int
  let executableLines: Int
  let functions: [CoverageFunction]
}

func usage() -> Never {
  fputs("usage: coverage_low.swift <coverage.json> [--threshold 80]\n", stderr)
  exit(2)
}

func percent(_ value: Double) -> String {
  String(format: "%.1f%%", value * 100)
}

func value<T>(_ dictionary: [String: Any], _ key: String, as _: T.Type) -> T? {
  dictionary[key] as? T
}

func localRelativePath(_ path: String, repoRoot: URL) -> String? {
  let url = URL(filePath: path)
  let relative = url.path(percentEncoded: false)
    .replacingOccurrences(of: repoRoot.path(percentEncoded: false) + "/", with: "")
  guard
    relative != path,
    relative.hasPrefix("sumika/")
      || relative.hasPrefix("Sources/SumikaApp/")
      || relative.hasPrefix("Sources/SumikaRuntimeMLX/")
      || relative.hasPrefix("Tests/SumikaAppTests/")
      || relative.hasPrefix("Tests/SumikaRuntimeMLXTests/")
  else {
    return nil
  }
  return relative
}

func isCompilerGenerated(_ name: String) -> Bool {
  let generatedPrefixes = [
    "closure #",
    "implicit closure #",
    "variable initialization expression",
  ]
  return generatedPrefixes.contains { name.hasPrefix($0) }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let jsonReport = arguments.first else {
  usage()
}

var threshold = 80.0
if arguments.count > 1 {
  guard arguments.count == 3, arguments[1] == "--threshold", let parsed = Double(arguments[2])
  else {
    usage()
  }
  threshold = parsed
}

let thresholdRatio = threshold / 100
let repoRoot = URL(filePath: FileManager.default.currentDirectoryPath)
let data = try Data(contentsOf: URL(filePath: jsonReport))
let report = try JSONSerialization.jsonObject(with: data) as? [String: Any]
let targets = value(report ?? [:], "targets", as: [[String: Any]].self) ?? []
var entries: [CoverageFile] = []

for target in targets {
  let files = value(target, "files", as: [[String: Any]].self) ?? []
  for file in files {
    guard
      let absolutePath = value(file, "path", as: String.self),
      let relativePath = localRelativePath(absolutePath, repoRoot: repoRoot)
    else {
      continue
    }

    let functions = (value(file, "functions", as: [[String: Any]].self) ?? []).compactMap {
      function -> CoverageFunction? in
      let name = value(function, "name", as: String.self) ?? "<unknown>"
      let executableLines = value(function, "executableLines", as: Int.self) ?? 0
      let lineCoverage = value(function, "lineCoverage", as: Double.self) ?? 0
      guard executableLines > 0, lineCoverage < thresholdRatio, !isCompilerGenerated(name) else {
        return nil
      }
      return CoverageFunction(
        name: name,
        lineCoverage: lineCoverage,
        executableLines: executableLines
      )
    }

    let lineCoverage = value(file, "lineCoverage", as: Double.self) ?? 0
    guard lineCoverage < thresholdRatio || !functions.isEmpty else {
      continue
    }

    entries.append(
      CoverageFile(
        path: relativePath,
        lineCoverage: lineCoverage,
        coveredLines: value(file, "coveredLines", as: Int.self) ?? 0,
        executableLines: value(file, "executableLines", as: Int.self) ?? 0,
        functions: functions.sorted { lhs, rhs in
          if lhs.lineCoverage == rhs.lineCoverage {
            return lhs.name < rhs.name
          }
          return lhs.lineCoverage < rhs.lineCoverage
        }
      )
    )
  }
}

entries.sort { lhs, rhs in
  if lhs.lineCoverage == rhs.lineCoverage {
    return lhs.path < rhs.path
  }
  return lhs.lineCoverage < rhs.lineCoverage
}

print("Local coverage below \(String(format: "%g", threshold))%")
if entries.isEmpty {
  print("No local files or functions below threshold.")
  exit(0)
}

for entry in entries {
  print(
    "\n\(entry.path)  \(percent(entry.lineCoverage)) "
      + "(\(entry.coveredLines)/\(entry.executableLines))"
  )
  for function in entry.functions {
    let paddedCoverage = percent(function.lineCoverage).leftPadding(toLength: 6)
    print("  \(paddedCoverage)  \(function.name)")
  }
}

print(
  "\n\(entries.count) local files have file or function coverage below "
    + "\(String(format: "%g", threshold))%."
)

extension String {
  func leftPadding(toLength length: Int) -> String {
    guard count < length else {
      return self
    }
    return String(repeating: " ", count: length - count) + self
  }
}
