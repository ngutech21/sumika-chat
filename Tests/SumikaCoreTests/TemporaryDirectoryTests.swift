import Foundation
import SumikaTestSupport
import Testing

struct TemporaryDirectoryTests {
  @Test
  func removesDirectoryAfterSuccessfulBody() throws {
    var directoryURL: URL?

    try withTemporaryDirectory { directory in
      directoryURL = directory
      #expect(FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))
    }

    let directory = try #require(directoryURL)
    #expect(!FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))
  }

  @Test
  func removesDirectoryAfterThrownBodyWithoutMaskingError() {
    var directoryURL: URL?

    #expect(throws: TemporaryDirectoryTestError.self) {
      try withTemporaryDirectory { directory in
        directoryURL = directory
        throw TemporaryDirectoryTestError.expected
      }
    }

    #expect(directoryURL != nil)
    if let directoryURL {
      #expect(
        !FileManager.default.fileExists(atPath: directoryURL.path(percentEncoded: false))
      )
    }
  }

  @Test
  func removesDirectoryAfterCancellation() async throws {
    let (directories, continuation) = AsyncStream<URL>.makeStream()
    let task = Task {
      try await withTemporaryDirectory { directory in
        continuation.yield(directory)
        try await Task.sleep(for: .seconds(30))
      }
    }
    let directory = try #require(await directories.first { _ in true })

    task.cancel()
    await #expect(throws: CancellationError.self) {
      try await task.value
    }

    #expect(!FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))
  }

  @Test
  func recordsCleanupFailure() {
    withKnownIssue("The body deliberately removes the owned directory.") {
      try withTemporaryDirectory { directory in
        try FileManager.default.removeItem(at: directory)
      }
    }
  }

  @Test
  func removesTemporaryItemIfPresentIdempotently() throws {
    try withTemporaryDirectory { directory in
      let item = directory.appending(path: "temporary-item", directoryHint: .notDirectory)
      try Data().write(to: item)

      removeTemporaryItemIfPresent(item)
      #expect(!FileManager.default.fileExists(atPath: item.path(percentEncoded: false)))

      removeTemporaryItemIfPresent(item)
    }
  }
}

private enum TemporaryDirectoryTestError: Error {
  case expected
}
