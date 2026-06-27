#!/usr/bin/env swift

import Foundation

let defaultSubsystem = "ngutech21.sumika-chat"
let defaultPredicate = "subsystem == \"\(defaultSubsystem)\""
let knownMetadataKeys: Set<String> = [
  "animated",
  "attachmentCount",
  "batchChars",
  "batchTokenEvents",
  "cacheEntries",
  "contentLengthBucket",
  "currentRows",
  "deleted",
  "inserted",
  "itemCount",
  "messageCount",
  "mode",
  "previousRows",
  "reason",
  "reloaded",
  "rowCount",
  "rowKind",
  "rows",
  "thinkingChars",
  "visibleChars",
  "visibleRows",
  "width",
]

struct IntervalRecord: Codable {
  var name: String
  var category: String?
  var durationMs: Double
  var metadata: [String: String]
}

struct MetricSummary: Codable {
  var count: Int
  var overThreshold: Int
  var totalMs: Double
  var p50Ms: Double
  var p90Ms: Double
  var p99Ms: Double
  var maxMs: Double
}

struct NamedSummary: Codable {
  var name: String
  var summary: MetricSummary
}

struct ContextSummary: Codable {
  var name: String
  var context: String
  var summary: MetricSummary
}

struct SignpostReport: Codable {
  var timestamp: String
  var gitCommit: String?
  var gitBranch: String?
  var scenario: String
  var source: String
  var predicate: String
  var thresholdMs: Double
  var intervalCount: Int
  var overall: [NamedSummary]
  var contexts: [ContextSummary]
  var slowIntervals: [IntervalRecord]
}

struct PartialInterval {
  var date: Date
  var metadata: [String: String]
}

struct LogEntry {
  var date: Date?
  var name: String?
  var category: String?
  var type: String?
  var signpostID: String?
  var durationMs: Double?
  var metadata: [String: String]
}

func usage() -> Never {
  fputs(
    """
    usage: chat_signpost_report.swift [options]

    options:
      --last <duration>       log window for /usr/bin/log show, default 20m
      --predicate <filter>    log predicate, default subsystem == "\(defaultSubsystem)"
      --input <path>          read JSON output from log show instead of invoking log show
      --output-dir <path>     directory for reports, default .perf/signposts
      --scenario <name>       scenario label, default manual-chat
      --threshold-ms <n>      slow-frame threshold, default 16
      --stdout-only           print summary without writing files
      --help                  show this help

    Example capture:
      /usr/bin/log show --last 20m --info --signpost --style json --predicate 'subsystem == "\(defaultSubsystem)"' > signposts.json
      xcrun swift script/chat_signpost_report.swift --input signposts.json

    The report only keeps allowlisted count, bucket, range, and reason metadata.
    """,
    stderr
  )
  exit(2)
}

func timestampForFileName(_ date: Date = Date()) -> String {
  let formatter = DateFormatter()
  formatter.calendar = Calendar(identifier: .gregorian)
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.timeZone = TimeZone(secondsFromGMT: 0)
  formatter.dateFormat = "yyyy-MM-dd'T'HHmmss'Z'"
  return formatter.string(from: date)
}

func timestampISO8601(_ date: Date = Date()) -> String {
  ISO8601DateFormatter().string(from: date)
}

func safeFileComponent(_ value: String) -> String {
  let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
  return String(value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
}

func gitValue(_ arguments: [String]) -> String? {
  let process = Process()
  process.executableURL = URL(filePath: "/usr/bin/git")
  process.arguments = arguments

  let pipe = Pipe()
  process.standardOutput = pipe
  process.standardError = Pipe()

  do {
    try process.run()
    process.waitUntilExit()
  } catch {
    return nil
  }

  guard process.terminationStatus == 0 else {
    return nil
  }

  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  let text = String(data: data, encoding: .utf8)?
    .trimmingCharacters(in: .whitespacesAndNewlines)
  return text?.isEmpty == false ? text : nil
}

func runLogShow(last: String, predicate: String) throws -> Data {
  let process = Process()
  process.executableURL = URL(filePath: "/usr/bin/log")
  process.arguments = [
    "show",
    "--last",
    last,
    "--info",
    "--signpost",
    "--style",
    "json",
    "--predicate",
    predicate,
  ]

  let output = Pipe()
  let errorOutput = Pipe()
  process.standardOutput = output
  process.standardError = errorOutput

  try process.run()
  process.waitUntilExit()

  let data = output.fileHandleForReading.readDataToEndOfFile()
  guard process.terminationStatus == 0 else {
    let errorData = errorOutput.fileHandleForReading.readDataToEndOfFile()
    let errorText = String(data: errorData, encoding: .utf8) ?? "unknown log show error"
    throw NSError(
      domain: "ChatSignpostReport",
      code: Int(process.terminationStatus),
      userInfo: [NSLocalizedDescriptionKey: errorText]
    )
  }
  return data
}

func parseLogObjects(from data: Data) throws -> [[String: Any]] {
  if data.isEmpty {
    return []
  }

  if let object = try? JSONSerialization.jsonObject(with: data) {
    if let array = object as? [[String: Any]] {
      return array
    }
    if let dictionary = object as? [String: Any] {
      return [dictionary]
    }
  }

  let text = String(data: data, encoding: .utf8) ?? ""
  return
    text
    .split(separator: "\n", omittingEmptySubsequences: true)
    .compactMap { row -> [String: Any]? in
      guard let rowData = String(row).data(using: .utf8) else {
        return nil
      }
      return (try? JSONSerialization.jsonObject(with: rowData)) as? [String: Any]
    }
}

func collectStrings(_ value: Any, into strings: inout [String]) {
  if let string = value as? String {
    strings.append(string)
  } else if let dictionary = value as? [String: Any] {
    for child in dictionary.values {
      collectStrings(child, into: &strings)
    }
  } else if let array = value as? [Any] {
    for child in array {
      collectStrings(child, into: &strings)
    }
  }
}

func stringValue(_ dictionary: [String: Any], keys: [String]) -> String? {
  for key in keys {
    if let value = dictionary[key] as? String, !value.isEmpty {
      return value
    }
    if let value = dictionary[key] as? CustomStringConvertible {
      let text = value.description
      if !text.isEmpty {
        return text
      }
    }
  }
  return nil
}

func doubleValue(_ value: Any?) -> Double? {
  if let value = value as? Double {
    return value
  }
  if let value = value as? Int {
    return Double(value)
  }
  if let value = value as? NSNumber {
    return value.doubleValue
  }
  if let value = value as? String {
    return Double(value)
  }
  return nil
}

func durationMs(_ dictionary: [String: Any]) -> Double? {
  for (key, value) in dictionary {
    let lowerKey = key.lowercased()
    guard lowerKey.contains("duration"), let parsed = doubleValue(value) else {
      continue
    }
    if lowerKey.contains("nano") || parsed > 1_000_000 {
      return parsed / 1_000_000
    }
    if lowerKey.contains("micro") {
      return parsed / 1_000
    }
    if lowerKey.contains("second"), !lowerKey.contains("ms"), !lowerKey.contains("milli") {
      return parsed * 1_000
    }
    return parsed
  }
  return nil
}

func parseDate(_ text: String?) -> Date? {
  guard let text else {
    return nil
  }

  let isoWithFractional = ISO8601DateFormatter()
  isoWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  if let date = isoWithFractional.date(from: text) {
    return date
  }

  let iso = ISO8601DateFormatter()
  if let date = iso.date(from: text) {
    return date
  }

  let formatter = DateFormatter()
  formatter.calendar = Calendar(identifier: .gregorian)
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.timeZone = TimeZone.current
  for format in [
    "yyyy-MM-dd HH:mm:ss.SSSSSSZ",
    "yyyy-MM-dd HH:mm:ss.SSSSSS",
    "yyyy-MM-dd HH:mm:ss.SSSZ",
    "yyyy-MM-dd HH:mm:ss.SSS",
  ] {
    formatter.dateFormat = format
    if let date = formatter.date(from: text) {
      return date
    }
  }
  return nil
}

func metadata(from dictionary: [String: Any]) -> [String: String] {
  var strings: [String] = []
  collectStrings(dictionary, into: &strings)

  let regex = try! NSRegularExpression(pattern: #"\b([A-Za-z][A-Za-z0-9_]*)=([^\s]+)"#)
  var result: [String: String] = [:]

  for text in strings {
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    for match in regex.matches(in: text, range: range) {
      guard
        let keyRange = Range(match.range(at: 1), in: text),
        let valueRange = Range(match.range(at: 2), in: text)
      else {
        continue
      }

      let key = String(text[keyRange])
      guard knownMetadataKeys.contains(key) else {
        continue
      }
      result[key] = String(text[valueRange])
    }
  }

  return result
}

func signpostName(from dictionary: [String: Any]) -> String? {
  stringValue(dictionary, keys: ["signpostName", "signpost_name", "name"])
}

func eventType(from dictionary: [String: Any]) -> String? {
  let explicit = stringValue(
    dictionary,
    keys: ["signpostType", "signpost_type", "eventType", "type"]
  )?.lowercased()
  if let explicit {
    return explicit
  }

  let message = stringValue(dictionary, keys: ["eventMessage", "message"])?.lowercased()
  if message?.contains("begin") == true {
    return "begin"
  }
  if message?.contains("end") == true {
    return "end"
  }
  if message?.contains("event") == true {
    return "event"
  }
  return nil
}

func logEntry(from dictionary: [String: Any]) -> LogEntry {
  LogEntry(
    date: parseDate(stringValue(dictionary, keys: ["timestamp", "date", "time"])),
    name: signpostName(from: dictionary),
    category: stringValue(dictionary, keys: ["category"]),
    type: eventType(from: dictionary),
    signpostID: stringValue(dictionary, keys: ["signpostID", "signpostId", "signpost_id"]),
    durationMs: durationMs(dictionary),
    metadata: metadata(from: dictionary)
  )
}

func intervalKey(_ entry: LogEntry) -> String {
  [
    entry.signpostID ?? "-",
    entry.category ?? "-",
    entry.name ?? "-",
  ].joined(separator: "|")
}

func intervals(from entries: [LogEntry]) -> [IntervalRecord] {
  var openIntervals: [String: [PartialInterval]] = [:]
  var records: [IntervalRecord] = []

  for entry in entries {
    guard let name = entry.name else {
      continue
    }

    let normalizedType = entry.type?.lowercased()
    if let duration = entry.durationMs, normalizedType?.contains("begin") != true,
      normalizedType?.contains("end") != true
    {
      records.append(
        IntervalRecord(
          name: name,
          category: entry.category,
          durationMs: duration,
          metadata: entry.metadata
        )
      )
      continue
    }

    guard let date = entry.date else {
      continue
    }

    let key = intervalKey(entry)
    if normalizedType?.contains("begin") == true {
      openIntervals[key, default: []].append(
        PartialInterval(date: date, metadata: entry.metadata)
      )
    } else if normalizedType?.contains("end") == true {
      guard var stack = openIntervals[key], let begin = stack.popLast() else {
        continue
      }
      if stack.isEmpty {
        openIntervals.removeValue(forKey: key)
      } else {
        openIntervals[key] = stack
      }
      records.append(
        IntervalRecord(
          name: name,
          category: entry.category,
          durationMs: date.timeIntervalSince(begin.date) * 1_000,
          metadata: begin.metadata.merging(entry.metadata) { current, _ in current }
        )
      )
    }
  }

  return records
}

func percentile(_ sortedValues: [Double], _ percentile: Double) -> Double {
  guard !sortedValues.isEmpty else {
    return 0
  }
  let index = max(
    0,
    min(sortedValues.count - 1, Int(ceil(percentile * Double(sortedValues.count))) - 1)
  )
  return sortedValues[index]
}

func summary(for records: [IntervalRecord], thresholdMs: Double) -> MetricSummary {
  let durations = records.map(\.durationMs).sorted()
  return MetricSummary(
    count: records.count,
    overThreshold: records.filter { $0.durationMs >= thresholdMs }.count,
    totalMs: durations.reduce(0, +),
    p50Ms: percentile(durations, 0.50),
    p90Ms: percentile(durations, 0.90),
    p99Ms: percentile(durations, 0.99),
    maxMs: durations.last ?? 0
  )
}

func contextKeys(for name: String) -> [String] {
  switch name {
  case "Transcript updateNSView":
    ["reason", "itemCount", "rowCount", "visibleRows"]
  case "Transcript apply snapshot":
    ["inserted", "deleted", "reloaded", "currentRows", "animated"]
  case "Transcript row height cache miss":
    ["rowKind", "contentLengthBucket", "reason"]
  case "Transcript height invalidation":
    ["reason", "rowCount", "rows"]
  case "Generation visible UI flush", "Generation thinking UI flush":
    ["batchTokenEvents", "batchChars", "visibleChars", "thinkingChars"]
  case "Generation stream reply":
    ["messageCount", "attachmentCount", "mode"]
  default:
    []
  }
}

func contextSignature(for record: IntervalRecord) -> String? {
  let keys = contextKeys(for: record.name)
  guard !keys.isEmpty else {
    return nil
  }
  let parts = keys.compactMap { key -> String? in
    guard let value = record.metadata[key] else {
      return nil
    }
    return "\(key)=\(value)"
  }
  return parts.isEmpty ? nil : parts.joined(separator: " ")
}

func formatted(_ value: Double) -> String {
  String(format: "%.1f", value)
}

func metadataText(_ metadata: [String: String]) -> String {
  guard !metadata.isEmpty else {
    return "-"
  }
  return metadata.keys.sorted().map { "\($0)=\(metadata[$0] ?? "")" }.joined(separator: " ")
}

func markdown(_ report: SignpostReport) -> String {
  var lines: [String] = [
    "# Chat Signpost Report",
    "",
    "- Timestamp: \(report.timestamp)",
    "- Scenario: \(report.scenario)",
    "- Git commit: \(report.gitCommit ?? "-")",
    "- Git branch: \(report.gitBranch ?? "-")",
    "- Source: \(report.source)",
    "- Predicate: `\(report.predicate)`",
    "- Threshold: \(formatted(report.thresholdMs)) ms",
    "- Intervals: \(report.intervalCount)",
    "",
    "## Overall",
    "",
    "| Signpost | Count | >= threshold | Total ms | p50 ms | p90 ms | p99 ms | Max ms |",
    "|---|---:|---:|---:|---:|---:|---:|---:|",
  ]

  for row in report.overall {
    let summary = row.summary
    lines.append(
      [
        row.name,
        "\(summary.count)",
        "\(summary.overThreshold)",
        formatted(summary.totalMs),
        formatted(summary.p50Ms),
        formatted(summary.p90Ms),
        formatted(summary.p99Ms),
        formatted(summary.maxMs),
      ].joined(separator: " | ").wrappedTableRow()
    )
  }

  if !report.contexts.isEmpty {
    lines.append(contentsOf: [
      "",
      "## Context Hotspots",
      "",
      "| Signpost | Context | Count | >= threshold | Total ms | p90 ms | Max ms |",
      "|---|---|---:|---:|---:|---:|---:|",
    ])

    for row in report.contexts {
      let summary = row.summary
      lines.append(
        [
          row.name,
          row.context,
          "\(summary.count)",
          "\(summary.overThreshold)",
          formatted(summary.totalMs),
          formatted(summary.p90Ms),
          formatted(summary.maxMs),
        ].joined(separator: " | ").wrappedTableRow()
      )
    }
  }

  if !report.slowIntervals.isEmpty {
    lines.append(contentsOf: [
      "",
      "## Slow Intervals",
      "",
      "| # | Signpost | Duration ms | Metadata |",
      "|---:|---|---:|---|",
    ])

    for (index, row) in report.slowIntervals.enumerated() {
      lines.append(
        [
          "\(index + 1)",
          row.name,
          formatted(row.durationMs),
          metadataText(row.metadata),
        ].joined(separator: " | ").wrappedTableRow()
      )
    }
  }

  lines.append("")
  return lines.joined(separator: "\n")
}

var last = "20m"
var predicate = defaultPredicate
var inputURL: URL?
var outputDirectory = URL(filePath: ".perf/signposts", directoryHint: .isDirectory)
var scenario = "manual-chat"
var thresholdMs = 16.0
var stdoutOnly = false

let arguments = Array(CommandLine.arguments.dropFirst())
var index = 0
while index < arguments.count {
  let argument = arguments[index]
  switch argument {
  case "--help", "-h":
    usage()
  case "--last":
    index += 1
    guard index < arguments.count else { usage() }
    last = arguments[index]
  case "--predicate":
    index += 1
    guard index < arguments.count else { usage() }
    predicate = arguments[index]
  case "--input":
    index += 1
    guard index < arguments.count else { usage() }
    inputURL = URL(filePath: arguments[index], directoryHint: .notDirectory)
  case "--output-dir":
    index += 1
    guard index < arguments.count else { usage() }
    outputDirectory = URL(filePath: arguments[index], directoryHint: .isDirectory)
  case "--scenario":
    index += 1
    guard index < arguments.count else { usage() }
    scenario = arguments[index]
  case "--threshold-ms":
    index += 1
    guard index < arguments.count, let parsed = Double(arguments[index]), parsed >= 0 else {
      usage()
    }
    thresholdMs = parsed
  case "--stdout-only":
    stdoutOnly = true
  default:
    usage()
  }
  index += 1
}

let source: String
let logData: Data
if let inputURL {
  source = inputURL.path(percentEncoded: false)
  logData = try Data(contentsOf: inputURL)
} else {
  source = "/usr/bin/log show --last \(last)"
  logData = try runLogShow(last: last, predicate: predicate)
}

let objects = try parseLogObjects(from: logData)
let entries = objects.map(logEntry(from:))
let records = intervals(from: entries)
let now = Date()

let overall = Dictionary(grouping: records, by: \.name)
  .map { name, rows in
    NamedSummary(name: name, summary: summary(for: rows, thresholdMs: thresholdMs))
  }
  .sorted {
    if $0.summary.overThreshold != $1.summary.overThreshold {
      return $0.summary.overThreshold > $1.summary.overThreshold
    }
    if $0.summary.maxMs != $1.summary.maxMs {
      return $0.summary.maxMs > $1.summary.maxMs
    }
    return $0.name < $1.name
  }

let contextRows = Dictionary(
  grouping: records.compactMap { record -> (String, String, IntervalRecord)? in
    guard let context = contextSignature(for: record) else {
      return nil
    }
    return (record.name, context, record)
  },
  by: { "\($0.0)|\($0.1)" }
)
.compactMap { _, rows -> ContextSummary? in
  guard let first = rows.first else {
    return nil
  }
  let records = rows.map(\.2)
  return ContextSummary(
    name: first.0,
    context: first.1,
    summary: summary(for: records, thresholdMs: thresholdMs)
  )
}
.sorted {
  if $0.summary.overThreshold != $1.summary.overThreshold {
    return $0.summary.overThreshold > $1.summary.overThreshold
  }
  if $0.summary.totalMs != $1.summary.totalMs {
    return $0.summary.totalMs > $1.summary.totalMs
  }
  return $0.name < $1.name
}

let slowIntervals =
  records
  .filter { $0.durationMs >= thresholdMs }
  .sorted { $0.durationMs > $1.durationMs }
  .prefix(30)

let report = SignpostReport(
  timestamp: timestampISO8601(now),
  gitCommit: gitValue(["rev-parse", "--short", "HEAD"]),
  gitBranch: gitValue(["branch", "--show-current"]),
  scenario: scenario,
  source: source,
  predicate: predicate,
  thresholdMs: thresholdMs,
  intervalCount: records.count,
  overall: overall,
  contexts: Array(contextRows.prefix(30)),
  slowIntervals: Array(slowIntervals)
)

let markdownText = markdown(report)
if stdoutOnly {
  print(markdownText)
  exit(0)
}

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let baseName = [
  timestampForFileName(now),
  safeFileComponent(scenario),
].joined(separator: "-")

let jsonURL = outputDirectory.appending(path: "\(baseName).json", directoryHint: .notDirectory)
let markdownURL = outputDirectory.appending(path: "\(baseName).md", directoryHint: .notDirectory)
let latestJSONURL = outputDirectory.appending(path: "latest.json", directoryHint: .notDirectory)
let latestMarkdownURL = outputDirectory.appending(path: "latest.md", directoryHint: .notDirectory)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
let jsonData = try encoder.encode(report)

try jsonData.write(to: jsonURL, options: .atomic)
try markdownText.write(to: markdownURL, atomically: true, encoding: .utf8)
try jsonData.write(to: latestJSONURL, options: .atomic)
try markdownText.write(to: latestMarkdownURL, atomically: true, encoding: .utf8)

print("Wrote \(jsonURL.path(percentEncoded: false))")
print("Wrote \(markdownURL.path(percentEncoded: false))")

extension String {
  func wrappedTableRow() -> String {
    "| " + self + " |"
  }
}
