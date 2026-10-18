import Foundation

@Observable
final class PullRequestsStore {
    /// The lists the panel shows. While `holdsOrder` is on they keep their order, and new pull
    /// requests wait in the `held…` lists.
    var authored: [PullRequestSummary] { authoredList.shown }
    var reviewRequests: [PullRequestSummary] { reviewList.shown }
    var heldAuthored: [PullRequestSummary] { authoredList.held }
    var heldReviewRequests: [PullRequestSummary] { reviewList.held }
    /// Every review request fetched, including ones held back while the panel is open.
    var allReviewRequests: [PullRequestSummary] { reviewList.all }
    /// Pull requests you reviewed or were asked to review, and what happened since: latest activity first.
    var history: [ReviewedPullRequest] { historyList.shown }
    var heldHistory: [ReviewedPullRequest] { historyList.held }
    /// While on, refreshes keep the shown order (see `StableList`). Turning it on or off shows
    /// everything that arrived.
    var holdsOrder = false {
        didSet { showAll() }
    }
    /// How many open pull requests you authored, which can be more than `authored` holds.
    private(set) var authoredTotal = 0
    /// False when GitHub had more review requests than DevInbox fetched.
    private(set) var hasAllReviewRequests = true
    /// Keyed by pull request node ID.
    private(set) var stacks: [String: StackInfo] = [:]
    private(set) var isRefreshing = false
    private(set) var lastUpdated: Date?
    /// Nil until the history has loaded.
    private(set) var historyUpdated: Date?
    private(set) var error: GitHubError?
    private(set) var restrictedOrganizations: Set<String> = []

    @ObservationIgnored var onUnauthorized: (() -> Void)?
    /// Called after each successful refresh.
    @ObservationIgnored var onUpdate: (() -> Void)?
    /// Review requests that left the list, for the history: GitHub's search only finds the ones you reviewed.
    @ObservationIgnored var leftReviewRequests: () -> [PastReviewRequest] = { [] }

    private var authoredList = StableList<PullRequestSummary>()
    private var reviewList = StableList<PullRequestSummary>()
    private var historyList = StableList<ReviewedPullRequest>()
    /// A refresh that should show everything arrived while another one was running.
    @ObservationIgnored private var showsAllAfterRefresh = false
    @ObservationIgnored private let client: GitHubClient
    @ObservationIgnored private let viewer: String
    @ObservationIgnored private var nativeStackCache: [String: (fetchedAt: Date, info: StackInfo?)] = [:]
    @ObservationIgnored private var repositoriesWithoutStacks: Set<String> = []
    /// The log only hears about changed counts, not every refresh.
    @ObservationIgnored private var loggedSummary: String?
    @ObservationIgnored private var loggedHistorySummary: String?
    /// Set when the history should refresh with the next refresh, however fresh it is.
    @ObservationIgnored private var historyIsStale = false
    /// The left requests the history was loaded with: a new one refreshes it.
    @ObservationIgnored private var historyLeftIDs: Set<String> = []

    private static let stackCacheLifetime: TimeInterval = 600
    /// The history changes slowly, and each refresh costs about 30 points of GitHub's hourly GraphQL
    /// budget of 5,000. It also refreshes on ⌘R, when a request leaves the list, and when it's unfolded.
    private static let historyLifetime: TimeInterval = 600

    init(client: GitHubClient, viewer: String) {
        self.client = client
        self.viewer = viewer
    }

    /// `showingAll` shows everything the refresh finds, even while holding: it's what ⌘R does.
    func refresh(showingAll: Bool = false) async {
        guard !isRefreshing else {
            if showingAll { showsAllAfterRefresh = true }
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        let holding = holdsOrder && !showingAll
        // The results are as of the search, not of the slower stack lookups that follow.
        let searchedAt = Date.now
        do {
            async let reviews = PullRequestSearch.fetch(PullRequestSearch.reviewRequestsQuery, client: client)
            async let mine = PullRequestSearch.fetch(PullRequestSearch.authoredQuery, client: client)
            let (reviewResult, authoredResult) = try await (reviews, mine)
            let holdsLists = holding && !showsAllAfterRefresh
            reviewList.update(reviewResult.pullRequests, holding: holdsLists)
            hasAllReviewRequests = reviewResult.isComplete
            authoredList.update(authoredResult.pullRequests, holding: holdsLists)
            showsAllAfterRefresh = false
            authoredTotal = authoredResult.totalCount
            restrictedOrganizations = reviewResult.restrictedOrganizations.union(authoredResult.restrictedOrganizations)
            let summary = "\(reviewResult.pullRequests.count) review requests\(reviewResult.isComplete ? "" : " (GitHub has more)"), "
                + "\(authoredResult.totalCount) open pull requests of yours"
                + (restrictedOrganizations.isEmpty ? "" : "; blocked by \(restrictedOrganizations.sorted().joined(separator: ", "))")
            if summary != loggedSummary {
                Log.info(.pullRequests, summary)
                loggedSummary = summary
            }
            await resolveStacks()
            lastUpdated = searchedAt
            error = nil
            onUpdate?()
            await refreshHistory(holding: holdsLists, force: showingAll)
        } catch let error as GitHubError {
            Log.error(.pullRequests, "Refresh failed: \(error.localizedDescription)")
            if error == .unauthorized { onUnauthorized?() }
            self.error = error
        } catch {
            Log.error(.pullRequests, "Refresh failed: \(error)")
            self.error = .network(error.localizedDescription)
        }
    }

    /// Shows the pull requests held back while the panel is open.
    func showAll() {
        authoredList.showAll()
        reviewList.showAll()
        historyList.showAll()
    }

    #if DEBUG
    /// Made-up pull requests for the demo snapshots, in place of the searches. Fresh, so the unfolded
    /// history doesn't ask for a refresh.
    func showDemo(
        reviewRequests: [PullRequestSummary], authored: [PullRequestSummary], history: [ReviewedPullRequest], stacks: [String: StackInfo]
    ) {
        reviewList.update(reviewRequests, holding: false)
        authoredList.update(authored, holding: false)
        historyList.update(history, holding: false)
        authoredTotal = authored.count
        self.stacks = stacks
        lastUpdated = .now
        historyUpdated = .now
    }
    #endif

    /// When the history is unfolded, or the panel opens with it unfolded: refresh it unless it's
    /// less than a minute old.
    func refreshHistoryIfStale() {
        if let historyUpdated, Date.now.timeIntervalSince(historyUpdated) < 60 { return }
        historyIsStale = true
        Task { await refresh() }
    }

    /// After the review requests: a request that left the list shows up here.
    private func refreshHistory(holding: Bool, force: Bool) async {
        let left = leftReviewRequests()
        let leftIDs = Set(left.map(\.id))
        let isFresh = historyUpdated.map { Date.now.timeIntervalSince($0) < Self.historyLifetime } ?? false
        guard force || historyIsStale || !isFresh || leftIDs != historyLeftIDs else { return }
        historyIsStale = false
        do {
            let fetched = try await ReviewHistorySearch.fetch(viewer: viewer, left: left, client: client)
            // Requests still waiting belong in the list above, unless you dismissed them.
            let waiting = Set(reviewList.all.map(\.id)).subtracting(leftIDs)
            let history = fetched.filter { !waiting.contains($0.id) }.sorted { $0.lastActivity > $1.lastActivity }
            historyList.update(history, holding: holding)
            historyUpdated = .now
            historyLeftIDs = leftIDs
            let unreviewed = history.count { [.requestDismissed, .requestEnded].contains($0.involvement) }
            let summary = "History: \(history.count) pull requests, \(unreviewed) of them without your review"
            if summary != loggedHistorySummary {
                Log.info(.pullRequests, summary)
                loggedHistorySummary = summary
            }
        } catch {
            Log.error(.pullRequests, "History refresh failed: \(error.localizedDescription)")
        }
    }

    private func resolveStacks() async {
        let all = Dictionary((authoredList.all + reviewList.all).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values
        let now = Date.now
        let toFetch = all.filter { pr in
            guard !repositoriesWithoutStacks.contains(pr.repository) else { return false }
            guard let cached = nativeStackCache[pr.subjectKey] else { return true }
            return now.timeIntervalSince(cached.fetchedAt) > Self.stackCacheLifetime
        }

        let client = client
        let lookups = await withTaskGroup(of: (PullRequestSummary, StacksAPI.Lookup?).self) { group in
            for pr in toFetch {
                group.addTask {
                    (pr, try? await StacksAPI.stack(repository: pr.repository, number: pr.number, client: client))
                }
            }
            var lookups: [(PullRequestSummary, StacksAPI.Lookup?)] = []
            for await lookup in group { lookups.append(lookup) }
            return lookups
        }
        for (pr, lookup) in lookups {
            switch lookup {
            case .stack(let info): nativeStackCache[pr.subjectKey] = (now, info)
            case .unsupported: repositoriesWithoutStacks.insert(pr.repository)
            case nil: break // transient failure: retry next refresh
            }
        }

        let candidates = Array(all)
        var resolved: [String: StackInfo] = [:]
        for pr in all {
            if let native = nativeStackCache[pr.subjectKey]?.info {
                resolved[pr.id] = native
            } else if let derived = StackResolver.fromBranches(for: pr, among: candidates) {
                resolved[pr.id] = derived
            }
        }
        stacks = resolved
    }
}
