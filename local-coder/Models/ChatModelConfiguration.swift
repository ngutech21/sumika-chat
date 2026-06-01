import Foundation

struct ChatModelConfiguration: Equatable, Sendable {
    let localModelDirectory: URL

    init(localModelDirectory: URL) {
        self.localModelDirectory = localModelDirectory
    }

    var displayPath: String {
        localModelDirectory.path(percentEncoded: false)
    }
}

enum LocalModelDirectory {
    static let defaultModelName = "gemma-3-4b-it-qat-4bit"

    static var defaultBaseURL: URL {
        let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]

        return applicationSupportURL
            .appending(path: "local-coder", directoryHint: .isDirectory)
            .appending(path: "Models", directoryHint: .isDirectory)
    }

    static var defaultModelURL: URL {
        defaultBaseURL.appending(path: defaultModelName, directoryHint: .isDirectory)
    }

    static func ensureDefaultBaseDirectoryExists() throws -> URL {
        let url = defaultBaseURL
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
