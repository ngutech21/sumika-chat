import Foundation

struct ChatModelConfiguration: Equatable, Sendable {
    let localModelDirectory: URL
    let contextTokenLimit: Int?

    init(localModelDirectory: URL, contextTokenLimit: Int? = nil) {
        self.localModelDirectory = localModelDirectory
        self.contextTokenLimit = contextTokenLimit
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

    static func readContextTokenLimit(from modelDirectory: URL) -> Int? {
        let configURL = modelDirectory.appending(path: "config.json", directoryHint: .notDirectory)
        guard
            let data = try? Data(contentsOf: configURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        return contextTokenLimit(in: object)
    }

    private static func contextTokenLimit(in object: [String: Any]) -> Int? {
        for key in ["max_position_embeddings", "max_seq_len", "seq_length", "n_ctx"] {
            if let value = object[key] as? Int {
                return value
            }

            if let value = object[key] as? Double {
                return Int(value)
            }
        }

        for value in object.values {
            if let nestedObject = value as? [String: Any],
               let nestedLimit = contextTokenLimit(in: nestedObject) {
                return nestedLimit
            }
        }

        return nil
    }
}
