import Foundation

@Observable
final class InboxStore {
    /// The threads the panel shows, latest activity first. While `holdsOrder` is on they keep their
    /// order, and new threads wait in `heldThreads`.
    var threads: [NotificationThread] { list.shown }
    /// Everything fetched, including threads held back while the panel is open.
    var allThreads: [NotificationThread] { list.all }
    var heldThreads: [NotificationThread] { list.held }
    /// While on, refreshes keep the shown order (see `StableList`). Turning it on or off shows
    /// everything that arrived.
    var holdsOrder = false {
        didSet { list.showAll() }
    }
    private(set) var details: [String: SubjectDetails] = [:]
    private(set) var isRefreshing = false
    private(set) var lastUpdated: Date?
    private(set) var error: GitHubError?
    private(set) var restrictedOrganizations: Set<String> = []
    private(set) var pollInterval: Duration = .seconds(60)

    /// Called after every successful update with all fresh threads (after enrichment), held ones too.
    @ObservationIgnored var onUpdate: (([NotificationThread]) -> Void)?
    @ObservationIgnored var onUnauthorized: (() -> Void)?

    private var list = StableList<NotificationThread>()
    @ObservationIgnored private let api: NotificationsAPI
    @ObservationIgnored private let viewer: String
    @ObservationIgnored private var lastModified: String?
    /// Reading notifications elsewhere doesn't change `Last-Modified`, so conditional polls never see
    /// it; a full fetch every few minutes does.
    @ObservationIgnored private var lastFullFetch: Date?
    /// A forced refresh (⌘R, wake) that arrived while a poll was running; it runs right after.
    @ObservationIgnored private var isForcedRefreshPending = false
    private static let fullFetchInterval: TimeInterval = 600
    @ObservationIgnored private var detailsUpdatedAt: [String: Date] = [:]
    /// Threads opened here win over responses of polls that were already in flight when they were opened.
    @ObservationIgnored private var locallyOpened: [String: Date] = [:]
    /// GitHub keeps listing threads marked read, so they stay hidden here (see `ReadThreads`).
    @ObservationIgnored private let readThreads: ReadThreads

    init(client: GitHubClient, viewer: String, readThreads: ReadThreads = ReadThreads()) {
        api = NotificationsAPI(client: client)
        self.viewer = viewer
        self.readThreads = readThreads
    }

    /// `force` fetches the full list even if GitHub would answer 304 for `Last-Modified`, and shows
    /// everything it finds: it's what ⌘R does.
    func refresh(force: Bool = false) async {
        guard !isRefreshing else {
            if force { isForcedRefreshPending = true }
            return
        }
        isRefreshing = true
        await fetchAndApply(force: force)
        isRefreshing = false
        if isForcedRefreshPending {
            isForcedRefreshPending = false
            await refresh(force: true)
        }
    }

    private func fetchAndApply(force: Bool) async {
        let isFullFetchDue = lastFullFetch.map { Date.now.timeIntervalSince($0) > Self.fullFetchInterval } ?? true
        do {
            switch try await api.fetch(ifModifiedSince: force || isFullFetchDue ? nil : lastModified) {
            case .notModified(let interval):
                updatePollInterval(interval)
            case .updated(let fetched, let lastModified, let interval):
                self.lastModified = lastModified
                lastFullFetch = .now
                updatePollInterval(interval)
                await enrich(fetched)
                // Threads and their details arrive together, so rows change once. Local actions apply
                // after the wait, so one taken during it isn't undone.
                let previous = Set(list.all.map(\.id))
                let threads = sortedByActivity(applyLocalActions(to: fetched))
                list.update(threads, holding: holdsOrder && !force)
                let changes = previous.isEmpty ? "" : "; \(threads.count { !previous.contains($0.id) }) new, "
                    + "\(previous.subtracting(threads.map(\.id)).count) gone since the last fetch"
                Log.info(.inbox, "GitHub lists \(fetched.count) threads (\(fetched.count(where: \.unread)) unread on GitHub), "
                    + "\(fetched.count - threads.count) of them marked read here\(changes)")
                onUpdate?(list.all)
            }
            lastUpdated = .now
            error = nil
        } catch let error as GitHubError {
            Log.error(.inbox, "Refresh failed: \(error.localizedDescription)")
            handle(error)
        } catch {
            Log.error(.inbox, "Refresh failed: \(error)")
            handle(.network(error.localizedDescription))
        }
    }

    func thread(id: String) -> NotificationThread? {
        list.all.first { $0.id == id }
    }

    /// The notification thread of a pull request. GitHub keeps one thread per subject, and its
    /// reason changes with the latest activity (a review request can turn into a mention).
    func threads(for pullRequest: PullRequestSummary) -> [NotificationThread] {
        threads(repository: pullRequest.repository, number: pullRequest.number)
    }

    func threads(repository: String, number: Int) -> [NotificationThread] {
        list.all.filter { $0.repository.fullName == repository && $0.number == number }
    }

    /// Shows the threads held back while the panel is open.
    func showAll() {
        list.showAll()
    }

    #if DEBUG
    func holdBack(_ count: Int) {
        list.holdBack(count)
    }

    /// Made-up threads for the demo snapshots, in place of a fetch.
    func showDemo(_ threads: [NotificationThread], details: [String: SubjectDetails]) {
        self.details = details
        list.update(sortedByActivity(threads), holding: false)
        lastUpdated = .now
    }
    #endif

    // MARK: - Actions

    /// Opening a thread marks it read on GitHub, like visiting it on github.com does. Here that only
    /// means opened: the thread loses its highlight but stays in the list until it's marked read.
    func markOpened(_ ids: [String]) async {
        let targets = ids.filter { id in list.all.contains { $0.id == id && $0.unread } }
        guard !targets.isEmpty else { return }
        let now = Date.now
        setUnread(false, for: targets)
        for id in targets { locallyOpened[id] = now }
        await perform("Opened", targets) { [api] in try await api.markRead(threadID: $0) } rollback: { failed in
            self.setUnread(true, for: failed)
            for id in failed { self.locallyOpened[id] = nil }
        }
    }

    /// Threads marked read but not sent to GitHub yet, so the action can still be taken back.
    struct PendingRead {
        fileprivate let threads: [NotificationThread]
        fileprivate let positions: [String: StableList<NotificationThread>.Position]

        var count: Int { threads.count }
    }

    /// Takes the threads out of the inbox now; `commit(_:)` tells GitHub, `undo(_:)` puts them back.
    /// GitHub can't take "done" back, so this split is what makes undo possible.
    func markReadLater(_ ids: [String]) -> PendingRead? {
        let ids = Set(ids)
        let removed = list.all.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return nil }
        let positions = list.positions(of: ids)
        list.modify { $0.removeAll { ids.contains($0.id) } }
        readThreads.mark(removed, at: .now)
        Log.info(.actions, "Marked read here: \(removed.map { "\($0.id) (\($0.logName))" }.joined(separator: ", "))")
        return PendingRead(threads: removed, positions: positions)
    }

    /// Read and done on GitHub: read, so GitHub's unread count agrees, and done, so the thread leaves
    /// the inbox on github.com too.
    func commit(_ pending: PendingRead) async {
        let unread = Set(pending.threads.filter(\.unread).map(\.id))
        await perform("Read and done", pending.threads.map(\.id)) { [api] id in
            if unread.contains(id) { try await api.markRead(threadID: id) }
            try await api.markDone(threadID: id)
        } rollback: { failed in
            self.putBack(pending, only: Set(failed))
        }
    }

    func undo(_ pending: PendingRead) {
        putBack(pending, only: nil)
    }

    /// Back where they were. A refresh in the meantime may have brought some back already (new activity).
    private func putBack(_ pending: PendingRead, only ids: Set<String>?) {
        let threads = pending.threads.filter { ids?.contains($0.id) ?? true }
        readThreads.unmark(threads.map(\.id))
        list.reinsert(threads, at: pending.positions)
    }

    func browserURL(for thread: NotificationThread) async -> URL {
        if let eventURL = details[thread.id]?.latestEvent?.url {
            return eventURL
        }
        switch URLMapping.target(for: thread) {
        case .browser(let url):
            return url
        case .resolve(let apiURL, let fallback):
            return (try? await api.htmlURL(forAPIResource: apiURL)) ?? fallback
        }
    }

    // MARK: - Private

    /// Runs `action` for each id, a few requests at a time ("mark all" can cover 200 threads),
    /// and rolls back the ones that failed. `name` says what it was in the log.
    private func perform(
        _ name: String,
        _ ids: [String],
        _ action: @escaping @Sendable (String) async throws -> Void,
        rollback: ([String]) -> Void
    ) async {
        let failures = await withTaskGroup(of: (id: String, error: (any Error)?).self) { group in
            var pending = ids.makeIterator()
            func startNext() {
                guard let id = pending.next() else { return }
                group.addTask {
                    do {
                        try await action(id)
                        return (id, nil)
                    } catch {
                        return (id, error)
                    }
                }
            }
            for _ in 0..<Self.maxConcurrentActions { startNext() }
            var failures: [(id: String, error: any Error)] = []
            for await result in group {
                if let error = result.error { failures.append((result.id, error)) }
                startNext()
            }
            return failures
        }
        guard let lastError = failures.last?.error else {
            Log.info(.actions, "\(name) sent to GitHub for \(ids.count) threads: \(ids.joined(separator: ", "))")
            return
        }
        let reasons = failures.map { "\($0.id): \($0.error.localizedDescription)" }
        Log.error(.actions, "\(name) failed for \(failures.count) of \(ids.count) threads, put back: \(reasons.joined(separator: "; "))")
        rollback(failures.map(\.id))
        handle(lastError as? GitHubError ?? .network(lastError.localizedDescription))
    }

    private static let maxConcurrentActions = 6

    private func setUnread(_ unread: Bool, for ids: [String]) {
        list.modify { threads in
            for index in threads.indices where ids.contains(threads[index].id) {
                threads[index].unread = unread
            }
        }
    }

    /// Latest activity first: the latest event where it's known, else when the thread last changed.
    private func sortedByActivity(_ threads: [NotificationThread]) -> [NotificationThread] {
        func date(_ thread: NotificationThread) -> Date {
            details[thread.id]?.latestEvent?.date ?? thread.updatedAt
        }
        return threads.sorted { date($0) > date($1) }
    }

    private func applyLocalActions(to fetched: [NotificationThread]) -> [NotificationThread] {
        let now = Date.now
        let cutoff = now.addingTimeInterval(-600)
        locallyOpened = locallyOpened.filter { $0.value > cutoff }
        return readThreads.removeRead(from: fetched, now: now).map { thread in
            var thread = thread
            if let openedAt = locallyOpened[thread.id], thread.updatedAt <= openedAt { thread.unread = false }
            return thread
        }
    }

    private func updatePollInterval(_ seconds: Int?) {
        pollInterval = .seconds(max(seconds ?? 60, 60))
    }

    private func handle(_ error: GitHubError) {
        if error == .unauthorized {
            onUnauthorized?()
        }
        self.error = error
    }

    private func enrich(_ threads: [NotificationThread]) async {
        // Forget threads that left the inbox, so the caches don't grow for as long as the app runs.
        let current = Set(threads.map(\.id))
        if details.keys.contains(where: { !current.contains($0) }) {
            details = details.filter { current.contains($0.key) }
        }
        detailsUpdatedAt = detailsUpdatedAt.filter { current.contains($0.key) }

        let stale = threads.filter { thread in
            thread.number != nil && detailsUpdatedAt[thread.id] != thread.updatedAt
        }
        let requests = stale.compactMap { thread in
            thread.number.map {
                SubjectEnrichment.Request(
                    key: thread.id,
                    owner: thread.repository.owner.login,
                    name: thread.repository.name,
                    number: $0
                )
            }
        }
        // Restricted subjects never get details, so they're requested again on every update: an
        // organization that approved access since drops out here instead of staying flagged.
        guard !requests.isEmpty else {
            setRestrictedOrganizations([])
            return
        }

        let batches = stride(from: 0, to: requests.count, by: SubjectEnrichment.batchSize).map {
            Array(requests[$0..<min($0 + SubjectEnrichment.batchSize, requests.count)])
        }
        let client = api.client
        let viewer = viewer
        let results = await withTaskGroup(of: SubjectEnrichment.Result?.self) { group in
            for batch in batches {
                group.addTask { try? await SubjectEnrichment.fetch(batch, viewer: viewer, client: client) }
            }
            var results: [SubjectEnrichment.Result] = []
            for await result in group {
                if let result { results.append(result) }
            }
            return results
        }

        let staleByID = Dictionary(stale.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for result in results {
            // When the inbox noticed a merge or close is hard to tell from the rows afterwards.
            for (key, new) in result.details {
                if let old = details[key]?.state, old != new.state, let thread = staleByID[key] {
                    Log.info(.inbox, "Thread \(key) (\(thread.logName)) is \(new.state) now, was \(old)")
                }
            }
            details.merge(result.details) { _, new in new }
            for key in result.details.keys {
                detailsUpdatedAt[key] = staleByID[key]?.updatedAt
            }
        }
        setRestrictedOrganizations(Set(results.flatMap(\.restrictedOrganizations)))
    }

    private func setRestrictedOrganizations(_ organizations: Set<String>) {
        guard organizations != restrictedOrganizations else { return }
        Log.info(.inbox, "Organizations blocking details: \(organizations.isEmpty ? "none" : organizations.sorted().joined(separator: ", "))")
        restrictedOrganizations = organizations
    }
}
