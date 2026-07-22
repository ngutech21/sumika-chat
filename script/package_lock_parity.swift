#!/usr/bin/env swift

import Foundation

struct ResolvedFile: Codable {
  struct Pin: Codable {
    let identity: String
    let kind: String
    let location: String
    let state: [String: String]
  }

  let originHash: String
  var pins: [Pin]
  let version: Int
}

func usage() -> Never {
  fputs(
    "usage: package_lock_parity.swift <check|sync> <root-Package.resolved> <xcode-Package.resolved>\n",
    stderr
  )
  exit(2)
}

func loadResolvedFile(at path: String) throws -> ResolvedFile {
  let data = try Data(contentsOf: URL(filePath: path))
  return try JSONDecoder().decode(ResolvedFile.self, from: data)
}

func pinsByIdentity(
  in resolvedFile: ResolvedFile,
  path: String
) throws -> [String: ResolvedFile.Pin] {
  var pins: [String: ResolvedFile.Pin] = [:]

  for pin in resolvedFile.pins {
    guard pins.updateValue(pin, forKey: pin.identity) == nil else {
      throw CocoaError(
        .fileReadCorruptFile,
        userInfo: [
          NSLocalizedDescriptionKey: "Duplicate package identity '\(pin.identity)' in \(path)"
        ]
      )
    }
  }

  return pins
}

func describe(_ state: [String: String]?) -> String {
  guard let state else {
    return "missing"
  }
  return state.keys.sorted().map { "\($0)=\(state[$0] ?? "")" }.joined(separator: ", ")
}

func write(_ resolvedFile: ResolvedFile, to path: String) throws {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  var data = try encoder.encode(resolvedFile)
  data.append(0x0A)
  try data.write(to: URL(filePath: path), options: Data.WritingOptions.atomic)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 3, arguments[0] == "check" || arguments[0] == "sync" else {
  usage()
}

do {
  let rootPath = arguments[1]
  let xcodePath = arguments[2]
  let rootResolvedFile = try loadResolvedFile(at: rootPath)
  var xcodeResolvedFile = try loadResolvedFile(at: xcodePath)
  guard rootResolvedFile.version == xcodeResolvedFile.version else {
    throw CocoaError(
      .fileReadCorruptFile,
      userInfo: [
        NSLocalizedDescriptionKey:
          "Package.resolved schema versions differ: root=\(rootResolvedFile.version), Xcode=\(xcodeResolvedFile.version)"
      ]
    )
  }
  let rootPinRecords = try pinsByIdentity(in: rootResolvedFile, path: rootPath)
  let xcodePinRecords = try pinsByIdentity(in: xcodeResolvedFile, path: xcodePath)
  let rootPins = rootPinRecords.mapValues(\.state)
  let xcodePins = xcodePinRecords.mapValues(\.state)
  let identities = Set(rootPins.keys).union(xcodePins.keys).sorted()

  guard Set(rootPins.keys) == Set(xcodePins.keys) else {
    let rootOnly = Set(rootPins.keys).subtracting(xcodePins.keys).sorted()
    let xcodeOnly = Set(xcodePins.keys).subtracting(rootPins.keys).sorted()
    if !rootOnly.isEmpty {
      fputs("Pins missing from Xcode lockfile: \(rootOnly.joined(separator: ", "))\n", stderr)
    }
    if !xcodeOnly.isEmpty {
      fputs("Pins missing from root lockfile: \(xcodeOnly.joined(separator: ", "))\n", stderr)
    }
    fputs("Resolve both package graphs before synchronizing their pins.\n", stderr)
    exit(1)
  }

  if arguments[0] == "sync" {
    xcodeResolvedFile.pins = try xcodeResolvedFile.pins.map { pin in
      guard let rootPin = rootPinRecords[pin.identity] else {
        throw CocoaError(.fileReadCorruptFile)
      }
      return ResolvedFile.Pin(
        identity: pin.identity,
        kind: pin.kind,
        location: pin.location,
        state: rootPin.state
      )
    }
    try write(xcodeResolvedFile, to: xcodePath)
    print("Synchronized \(identities.count) Xcode package pins with the root lockfile.")
    exit(0)
  }

  let mismatches = identities.filter { rootPins[$0] != xcodePins[$0] }

  guard mismatches.isEmpty else {
    fputs("Package lockfiles resolve different pins:\n", stderr)
    for identity in mismatches {
      fputs("  \(identity):\n", stderr)
      fputs("    root:  \(describe(rootPins[identity]))\n", stderr)
      fputs("    Xcode: \(describe(xcodePins[identity]))\n", stderr)
    }
    fputs("Run `just resolve-packages` and commit both Package.resolved files.\n", stderr)
    exit(1)
  }

  print("Package lockfiles resolve \(identities.count) identical pins.")
} catch {
  fputs("Failed to compare package lockfiles: \(error.localizedDescription)\n", stderr)
  exit(1)
}
