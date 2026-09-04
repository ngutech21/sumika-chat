import Foundation

enum ProcessOutputRetention: Equatable, Sendable {
  case prefix
  case headTail
  case tail
}

/// Ingestion and text projection share one byte budget. Raw prefix captures
/// remain suitable for binary protocols such as Git's NUL-delimited paths.
struct ProcessOutputCapture {
  struct Snapshot: Sendable {
    var data: Data
    var text: String
    var omittedBytes: Int
  }

  let limit: Int
  let retention: ProcessOutputRetention
  private var head = Data()
  private var tail: ProcessByteTail
  private var totalBytes = 0

  init(limit: Int, retention: ProcessOutputRetention) {
    self.limit = max(0, limit)
    self.retention = retention
    tail = ProcessByteTail(
      capacity: retention == .prefix ? 0 : (retention == .tail ? max(0, limit) : max(0, limit) / 2)
    )
  }

  mutating func append(_ data: Data) {
    let (sum, overflow) = totalBytes.addingReportingOverflow(data.count)
    totalBytes = overflow ? Int.max : sum
    let headLimit = retention == .prefix ? limit : (retention == .headTail ? limit - limit / 2 : 0)
    let added = min(max(headLimit - head.count, 0), data.count)
    head.append(data.prefix(added))
    if retention != .prefix {
      tail.append(data.dropFirst(added))
    }
  }

  func snapshot() -> Snapshot {
    let tailData = tail.data
    let omitted = max(0, totalBytes - head.count - tailData.count)
    guard retention == .headTail, omitted > 0 else {
      let data = head + tailData
      return Snapshot(
        data: data,
        text: Self.decodedText(data),
        omittedBytes: omitted
      )
    }

    var marker = "\n[... \(totalBytes) bytes omitted during capture ...]\n"
    if marker.utf8.count > limit / 2 {
      marker = limit >= 5 ? "[...]" : String(repeating: ".", count: min(limit, 3))
    }
    // Reserving for totalBytes also reserves enough digits for omittedBytes.
    let available = max(0, limit - marker.utf8.count)
    let keptHead = Data(head.prefix((available + 1) / 2))
    let keptTail = Data(tailData.suffix(available / 2))
    let omittedBytes = totalBytes - keptHead.count - keptTail.count
    if marker.contains("bytes omitted") {
      marker = "\n[... \(omittedBytes) bytes omitted during capture ...]\n"
    }
    let text = Self.decodedText(keptHead) + marker + Self.decodedText(keptTail)
    return Snapshot(data: keptHead + keptTail, text: text, omittedBytes: omittedBytes)
  }

  private static func decodedText(_ data: Data) -> String {
    if let text = String(data: data, encoding: .utf8) { return text }
    // A one-byte placeholder for malformed UTF-8 cannot expand the retained
    // byte budget or silently discard later diagnostics. Valid scalars keep
    // their original encoding, including genuine replacement characters.
    var decoder = Unicode.UTF8()
    var bytes = data.makeIterator()
    var text = ""
    text.reserveCapacity(data.count)
    while true {
      switch decoder.decode(&bytes) {
      case .scalarValue(let scalar):
        text.unicodeScalars.append(scalar)
      case .error:
        text.append("?")
      case .emptyInput:
        return text
      }
    }
  }
}

/// Fixed-size ring, so retaining a diagnostic tail never shifts the full
/// retained output for every pipe read.
private struct ProcessByteTail {
  private var storage: Data
  private var position = 0
  private var count = 0

  init(capacity: Int) {
    storage = Data(count: capacity)
  }

  mutating func append(_ data: Data) {
    guard !storage.isEmpty, !data.isEmpty else { return }
    let incoming = data.suffix(storage.count)
    let firstCount = min(incoming.count, storage.count - position)
    storage.replaceSubrange(position..<(position + firstCount), with: incoming.prefix(firstCount))
    if firstCount < incoming.count {
      storage.replaceSubrange(
        0..<(incoming.count - firstCount), with: incoming.dropFirst(firstCount))
    }
    position = (position + incoming.count) % storage.count
    count = min(storage.count, count + incoming.count)
  }

  var data: Data {
    guard count == storage.count else { return Data(storage.prefix(count)) }
    return storage.suffix(from: position) + storage.prefix(position)
  }
}
