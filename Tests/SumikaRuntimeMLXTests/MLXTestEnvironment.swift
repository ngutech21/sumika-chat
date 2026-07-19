import Foundation

nonisolated func mlxDefaultMetalLibraryAvailable() -> Bool {
  #if os(macOS)
    let fileManager = FileManager.default
    let resourceRoots =
      [Bundle.main.resourceURL]
      + Bundle.allBundles.map(\.resourceURL)
      + Bundle.allFrameworks.map(\.resourceURL)

    return resourceRoots.compactMap(\.self).contains { rootURL in
      let bundleURL = rootURL.appending(
        path: "mlx-swift_Cmlx.bundle",
        directoryHint: .isDirectory
      )
      return [
        bundleURL.appending(path: "default.metallib", directoryHint: .notDirectory),
        bundleURL.appending(
          path: "Contents/Resources/default.metallib",
          directoryHint: .notDirectory
        ),
      ].contains { fileManager.fileExists(atPath: $0.path(percentEncoded: false)) }
    }
  #else
    return false
  #endif
}
