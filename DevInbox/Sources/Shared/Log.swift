import Foundation

/// What the app did and what went wrong, one line per event in ~/Library/Logs/DevInbox/DevInbox.log,
/// so a problem can be traced afterwards. Past 2 MB the file moves to DevInbox.1.log, replacing the
/// one before. Never log the token or response bodies.
nonisolated enum Log {
    enum Category: String, Sendable {
        case app, auth, inbox, pullRequests = "prs", actions, github, banners
    }

    static func info(_ category: Category, _ message: String) {
        LogFile.shared?.append(category: category, message: message, isError: false)
    }

    /// Something failed that the user would want fixed. These lines start with "ERROR".
    static func error(_ category: Category, _ message: String) {
        LogFile.shared?.append(category: category, message: message, isError: true)
    }

    /// Waits until every line is on disk; lines still queued when the app exits would be lost.
    static func flush() {
        LogFile.shared?.flush()
    }

    static var directory: URL {
        URL.libraryDirectory.appending(path: "Logs/DevInbox", directoryHint: .isDirectory)
    }
}

private nonisolated final class LogFile: @unchecked Sendable {
    /// Nil for tests and the debug render modes: they run against the real account and settings,
    /// but what they do isn't what the app did.
    static let shared: LogFile? = {
        let process = ProcessInfo.processInfo
        let isTest = process.environment["XCTestConfigurationFilePath"] != nil
        let isDebugMode = process.arguments.contains { $0 == "--snapshot" || $0 == "--scroll-benchmark" }
        return isTest || isDebugMode ? nil : LogFile(directory: Log.directory)
    }()

    private static let maxSize: UInt64 = 2_000_000
    /// Local time with its offset, e.g. 2026-10-11T15:17:02.123+02:00.
    private static let timeFormat = Date.ISO8601FormatStyle(timeZoneSeparator: .colon, includingFractionalSeconds: true, timeZone: .autoupdatingCurrent)

    private let url: URL
    private let previousURL: URL
    /// Everything below is only touched on this queue, so logging never waits for the disk.
    private let queue = DispatchQueue(label: "eu.forml.DevInbox.log", qos: .utility)
    private var handle: FileHandle?
    private var size: UInt64 = 0

    private init(directory: URL) {
        url = directory.appending(path: "DevInbox.log")
        previousURL = directory.appending(path: "DevInbox.1.log")
    }

    func append(category: Log.Category, message: String, isError: Bool) {
        let date = Date.now
        queue.async { [self] in
            let line = "\(date.formatted(Self.timeFormat)) \(isError ? "ERROR " : "")[\(category.rawValue)] \(message)\n"
            write(Data(line.utf8))
        }
    }

    func flush() {
        queue.sync {}
    }

    private func write(_ data: Data) {
        if handle == nil { open() }
        guard let handle, (try? handle.write(contentsOf: data)) != nil else { return }
        size += UInt64(data.count)
        if size > Self.maxSize { rotate() }
    }

    private func open() {
        let files = FileManager.default
        try? files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !files.fileExists(atPath: url.path) {
            files.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        size = (try? handle?.seekToEnd()) ?? 0
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: previousURL)
        try? FileManager.default.moveItem(at: url, to: previousURL)
    }
}
