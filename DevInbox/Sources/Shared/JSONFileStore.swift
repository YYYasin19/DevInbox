import Foundation

/// Small Codable value persisted as JSON in ~/Library/Application Support/DevInbox.
nonisolated struct JSONFileStore<Value: Codable>: Sendable {
    let url: URL

    init(name: String, directory: URL = JSONFileStore.defaultDirectory) {
        url = directory.appending(path: name)
    }

    static var defaultDirectory: URL {
        #if DEBUG
        // The demo snapshots must neither show nor change the real snoozes, dismissals and read marks.
        if DemoSnapshot.isRequested { return DemoSnapshot.storageDirectory }
        #endif
        return URL.applicationSupportDirectory.appending(path: "DevInbox", directoryHint: .isDirectory)
    }

    func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Value.self, from: data)
    }

    func save(_ value: Value) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}
