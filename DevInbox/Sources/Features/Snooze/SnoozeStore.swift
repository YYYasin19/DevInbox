import Foundation

nonisolated struct SnoozeEntry: Codable, Hashable, Sendable {
    var until: Date
    /// Notifications only: the thread's `updated_at` at snooze time. Newer activity wakes it early.
    var updatedAtWhenSnoozed: Date?
    var title: String
    var subtitle: String
    /// Set on notification entries created alongside a review snooze; they're listed via the review.
    var linkedReviewKey: String?

    func isActive(now: Date, currentUpdatedAt: Date?) -> Bool {
        guard now < until else { return false }
        if let snoozedAt = updatedAtWhenSnoozed, let currentUpdatedAt, currentUpdatedAt > snoozedAt {
            return false
        }
        return true
    }
}

nonisolated enum SnoozeOption: CaseIterable, Identifiable, Sendable {
    case oneHour, threeHours, tomorrowMorning, nextMonday

    var id: Self { self }

    var title: String {
        switch self {
        case .oneHour: "1 hour"
        case .threeHours: "3 hours"
        case .tomorrowMorning: "Tomorrow, 9:00"
        case .nextMonday: "Next Monday, 9:00"
        }
    }

    func date(from now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .oneHour:
            return now.addingTimeInterval(3600)
        case .threeHours:
            return now.addingTimeInterval(3 * 3600)
        case .tomorrowMorning:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)!
        case .nextMonday:
            let monday = calendar.nextDate(after: now, matching: DateComponents(hour: 9, minute: 0, weekday: 2), matchingPolicy: .nextTime)!
            // On a Monday before 9:00 that's today, but "next Monday" means a week later.
            return calendar.isDate(monday, inSameDayAs: now) ? calendar.date(byAdding: .day, value: 7, to: monday)! : monday
        }
    }
}

@Observable
final class SnoozeStore {
    private(set) var entries: [String: SnoozeEntry]
    @ObservationIgnored private let file: JSONFileStore<[String: SnoozeEntry]>

    init(file: JSONFileStore<[String: SnoozeEntry]> = .init(name: "snoozes.json")) {
        self.file = file
        entries = file.load() ?? [:]
    }

    static func key(for thread: NotificationThread) -> String { "notification:\(thread.id)" }
    static func key(forReview pullRequest: PullRequestSummary) -> String { "review:\(pullRequest.id)" }

    func snooze(_ thread: NotificationThread, until: Date) {
        entries[Self.key(for: thread)] = SnoozeEntry(
            until: until,
            updatedAtWhenSnoozed: thread.updatedAt,
            title: thread.subject.title,
            subtitle: thread.number.map { "\(thread.repository.fullName) #\($0)" } ?? thread.repository.fullName
        )
        persist()
    }

    /// Reviews only wake up when the time is over. The matching review-request notification is
    /// snoozed along with it so the inbox doesn't keep nagging either.
    func snooze(review pullRequest: PullRequestSummary, until: Date, relatedThread: NotificationThread?) {
        let reviewKey = Self.key(forReview: pullRequest)
        entries[reviewKey] = SnoozeEntry(
            until: until,
            title: pullRequest.title,
            subtitle: "\(pullRequest.repository) #\(pullRequest.number)"
        )
        if let relatedThread {
            // Like the review, it only wakes on time, not on new activity.
            entries[Self.key(for: relatedThread)] = SnoozeEntry(
                until: until,
                title: relatedThread.subject.title,
                subtitle: pullRequest.repository,
                linkedReviewKey: reviewKey
            )
        }
        persist()
    }

    func isSnoozed(_ thread: NotificationThread, now: Date = .now) -> Bool {
        entries[Self.key(for: thread)]?.isActive(now: now, currentUpdatedAt: thread.updatedAt) ?? false
    }

    func isSnoozed(review pullRequest: PullRequestSummary, now: Date = .now) -> Bool {
        entries[Self.key(forReview: pullRequest)]?.isActive(now: now, currentUpdatedAt: nil) ?? false
    }

    func unsnooze(key: String) {
        entries[key] = nil
        for (linkedKey, entry) in entries where entry.linkedReviewKey == key {
            entries[linkedKey] = nil
        }
        persist()
    }

    /// Entries listed in the "Snoozed" section (linked notification entries are represented by their review).
    var visibleEntries: [(key: String, entry: SnoozeEntry)] {
        entries
            .filter { $0.value.linkedReviewKey == nil }
            .map { (key: $0.key, entry: $0.value) }
            .sorted { $0.entry.until < $1.entry.until }
    }

    var nextWakeDate: Date? { entries.values.map(\.until).min() }

    /// Removes entries that woke up (time passed, or new activity on the thread).
    func prune(threads: [NotificationThread]? = nil, now: Date = .now) {
        let updatedAtByKey = Dictionary(
            (threads ?? []).map { (Self.key(for: $0), $0.updatedAt) },
            uniquingKeysWith: { first, _ in first }
        )
        let woken = entries.filter { key, entry in
            !entry.isActive(now: now, currentUpdatedAt: updatedAtByKey[key])
        }
        guard !woken.isEmpty else { return }
        for key in woken.keys {
            entries[key] = nil
        }
        persist()
    }

    private func persist() {
        file.save(entries)
    }
}
