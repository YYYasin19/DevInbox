import Foundation

/// Threads checked off with the checkmark: read and done on GitHub. GitHub keeps listing them in
/// `GET /notifications?all=true` anyway (Done answers 204 and changes nothing there), so the inbox
/// hides them itself until they have new activity. Kept on disk, so they stay hidden after a restart.
final class ReadThreads {
    /// Per thread: when it was marked read, or its `updated_at` if that's later (clock skew).
    private var readAt: [String: Date]
    private let file: JSONFileStore<[String: Date]>

    /// Marks of threads GitHub stopped listing are kept this long, in case they show up again.
    private static let unlistedLifetime: TimeInterval = 30 * 86_400

    init(file: JSONFileStore<[String: Date]> = .init(name: "read.json")) {
        self.file = file
        readAt = file.load() ?? [:]
    }

    func mark(_ threads: [NotificationThread], at date: Date) {
        for thread in threads {
            readAt[thread.id] = max(date, thread.updatedAt)
        }
        file.save(readAt)
    }

    func unmark(_ ids: [String]) {
        for id in ids { readAt[id] = nil }
        file.save(readAt)
    }

    /// Leaves out read threads without new activity. Forgets threads with new activity (they're
    /// unread on GitHub again) and ones GitHub hasn't listed for a while.
    func removeRead(from threads: [NotificationThread], now: Date) -> [NotificationThread] {
        let before = readAt
        let kept = threads.filter { thread in
            guard let date = readAt[thread.id] else { return true }
            guard thread.updatedAt > date else { return false }
            Log.info(.inbox, "Thread \(thread.id) (\(thread.logName)) has new activity since it was marked read, showing it again")
            readAt[thread.id] = nil
            return true
        }
        let listed = Set(threads.map(\.id))
        readAt = readAt.filter { listed.contains($0.key) || now.timeIntervalSince($0.value) < Self.unlistedLifetime }
        if readAt != before { file.save(readAt) }
        return kept
    }
}
