import Foundation

nonisolated enum ReviewRequestSignal {
    /// Review requests you haven't seen: unread review-request notifications for reviews that are still
    /// waiting. A notification newer than the last pull request search counts too, because its review
    /// just hasn't been loaded yet.
    static func unseenCount(threads: [NotificationThread], waiting: [PullRequestSummary], searchedAt: Date?) -> Int {
        let waitingKeys = Set(waiting.map(\.subjectKey))
        return threads.count { thread in
            guard thread.unread, thread.reason == .reviewRequested, let key = thread.subjectKey else { return false }
            if waitingKeys.contains(key) { return true }
            return searchedAt.map { thread.updatedAt > $0 } ?? true
        }
    }

    /// Whether a review request arrived after the last search, so the Reviews tab is behind.
    static func needsSearch(threads: [NotificationThread], searchedAt: Date?) -> Bool {
        let searchedAt = searchedAt ?? .distantPast
        return threads.contains { $0.unread && $0.reason == .reviewRequested && $0.updatedAt > searchedAt }
    }
}

/// A review request you don't plan to act on.
nonisolated struct DismissedReview: Codable, Hashable, Sendable {
    var title: String
    var repository: String
    var number: Int
    var dismissedAt: Date
    /// Shown in "Snoozed & dismissed". Removing it from that list keeps the review hidden.
    var isListed = true

    /// How long a dismissed review stays in the list.
    static let listedDuration: TimeInterval = 30 * 86_400

    var subjectKey: String { "\(repository)#\(number)" }

    func isShownInList(now: Date) -> Bool {
        isListed && now.timeIntervalSince(dismissedAt) < Self.listedDuration
    }

    init(title: String, repository: String, number: Int, dismissedAt: Date, isListed: Bool = true) {
        self.title = title
        self.repository = repository
        self.number = number
        self.dismissedAt = dismissedAt
        self.isListed = isListed
    }

    private enum CodingKeys: String, CodingKey {
        case title, repository, number, dismissedAt, isListed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        repository = try container.decode(String.self, forKey: .repository)
        number = try container.decode(Int.self, forKey: .number)
        dismissedAt = try container.decode(Date.self, forKey: .dismissedAt)
        // Saved before the list could be cleaned up.
        isListed = try container.decodeIfPresent(Bool.self, forKey: .isListed) ?? true
    }
}

/// Review requests hidden on purpose. A dismissal lasts as long as GitHub keeps requesting your review
/// on that pull request: once the request is gone, a new one shows up again.
@Observable
final class DismissedReviewStore {
    /// Keyed by `subjectKey` ("owner/repo#123"), so both a review and its notification can dismiss it.
    private(set) var entries: [String: DismissedReview]

    @ObservationIgnored private let file: JSONFileStore<[String: DismissedReview]>

    init(file: JSONFileStore<[String: DismissedReview]> = JSONFileStore(name: "dismissed-reviews.json")) {
        self.file = file
        // Re-keyed on load: the first version stored them by pull request node ID.
        let stored = file.load() ?? [:]
        entries = Dictionary(stored.values.map { ($0.subjectKey, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// What "Snoozed & dismissed" lists, newest first: dismissed in the last 30 days and not removed.
    func listedEntries(now: Date = .now) -> [(key: String, review: DismissedReview)] {
        entries
            .filter { $0.value.isShownInList(now: now) }
            .map { (key: $0.key, review: $0.value) }
            .sorted { $0.review.dismissedAt > $1.review.dismissedAt }
    }

    func contains(_ pullRequest: PullRequestSummary) -> Bool {
        entries[pullRequest.subjectKey] != nil
    }

    /// Whether the thread is the review-request notification of a dismissed review. Threads with
    /// another reason, such as a mention on the same pull request, still show.
    func hides(_ thread: NotificationThread) -> Bool {
        guard thread.reason == .reviewRequested, let key = thread.subjectKey else { return false }
        return entries[key] != nil
    }

    func dismiss(_ review: DismissedReview) {
        entries[review.subjectKey] = review
        file.save(entries)
    }

    func restore(key: String) {
        entries[key] = nil
        file.save(entries)
    }

    /// Takes it off the list; the review stays hidden.
    func unlist(key: String) {
        entries[key]?.isListed = false
        file.save(entries)
    }

    /// Forgets dismissals whose request is gone (reviewed, withdrawn or closed). Only call this with the
    /// complete list of requested reviews.
    func prune(keeping requested: [PullRequestSummary]) {
        let keys = Set(requested.map(\.subjectKey))
        let kept = entries.filter { keys.contains($0.key) }
        guard kept.count != entries.count else { return }
        entries = kept
        file.save(entries)
    }
}

/// A review request DevInbox has seen. GitHub's search only finds pull requests you reviewed, so the
/// history remembers requests itself to show what happened after they left the list without a review.
nonisolated struct PastReviewRequest: Codable, Hashable, Sendable {
    /// The pull request's node ID.
    var id: String
    /// When your review was last requested, as far as DevInbox knows.
    var requestedAt: Date
    /// When it left the Reviews list: the request ended, or you dismissed it. Nil while it's waiting.
    var leftAt: Date?
    var wasDismissed = false
}

/// Review requests while they wait, and for 30 days after they leave the list.
final class PastReviewRequestStore {
    /// Keyed by pull request node ID.
    private(set) var entries: [String: PastReviewRequest]

    private let file: JSONFileStore<[String: PastReviewRequest]>

    init(file: JSONFileStore<[String: PastReviewRequest]> = JSONFileStore(name: "past-review-requests.json")) {
        self.file = file
        entries = file.load() ?? [:]
    }

    /// Requests that left the list, the latest first: at most 100, what one GraphQL `nodes` lookup takes.
    var left: [PastReviewRequest] {
        let left = entries.values.compactMap { entry in entry.leftAt.map { (entry, $0) } }
        return left.sorted { $0.1 > $1.1 }.prefix(100).map(\.0)
    }

    /// Records the requests waiting now; the ones missing have left. Only call this with the complete
    /// list of requested reviews.
    func update(requested: [PullRequestSummary], viewer: String, dismissedAt: (PullRequestSummary) -> Date?, now: Date = .now) {
        var updated = entries
        for pullRequest in requested {
            let dismissed = dismissedAt(pullRequest)
            updated[pullRequest.id] = PastReviewRequest(
                id: pullRequest.id,
                requestedAt: pullRequest.reviewRequestedAt(viewer: viewer) ?? updated[pullRequest.id]?.requestedAt ?? now,
                leftAt: dismissed,
                wasDismissed: dismissed != nil
            )
        }
        let requestedIDs = Set(requested.map(\.id))
        for (id, entry) in updated where entry.leftAt == nil && !requestedIDs.contains(id) {
            updated[id]?.leftAt = now
        }
        updated = updated.filter { $0.value.leftAt.map { now.timeIntervalSince($0) < ReviewHistorySearch.window } ?? true }
        guard updated != entries else { return }
        entries = updated
        file.save(entries)
    }
}
