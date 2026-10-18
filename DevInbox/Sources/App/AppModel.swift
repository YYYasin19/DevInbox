import AppKit

enum PanelTab: String, CaseIterable, Identifiable {
    case inbox, reviews, myPullRequests

    var id: Self { self }

    var title: String {
        switch self {
        case .inbox: "Inbox"
        case .reviews: "Reviews"
        case .myPullRequests: "My PRs"
        }
    }

    var help: String {
        switch self {
        case .inbox: "Your GitHub notifications (⌘1)"
        case .reviews: "Pull requests waiting for your review (⌘2)"
        case .myPullRequests: "Your open pull requests and their status (⌘3)"
        }
    }
}

struct MenuBarState: Equatable {
    var unread = 0
    var pendingReviews = 0
    /// Review requests whose notification is still unread.
    var newReviewRequests = 0
    var isSignedIn = false
}

@Observable
final class AppModel {
    enum AuthState {
        case checking
        case signedOut(GitHubCLI.TokenError)
        case signedIn(Session)
    }

    private(set) var auth: AuthState = .checking
    var selectedTab: PanelTab = .inbox
    var isShowingSnoozed = false
    /// Incremented each time the panel opens, so lists can take keyboard focus again.
    private(set) var panelOpenCount = 0
    /// Settings is recording a new shortcut: the current one mustn't fire meanwhile.
    var isRecordingShortcut = false
    /// Another app already registered the shortcut that opens the panel.
    var isShortcutTaken = false

    let settings = AppSettings()
    let snoozes = SnoozeStore()
    let dismissedReviews = DismissedReviewStore()
    @ObservationIgnored let pastReviewRequests = PastReviewRequestStore()
    let undo = UndoCenter()
    let updater = Updater()
    @ObservationIgnored let banners = BannerNotifier()

    /// Wired up by the AppDelegate.
    @ObservationIgnored var openSettingsAction: () -> Void = {}
    @ObservationIgnored var closePanelAction: () -> Void = {}

    @ObservationIgnored private var isConnecting = false
    @ObservationIgnored private var activeToken: String?
    @ObservationIgnored private var snoozeTimer: Task<Void, Never>?
    @ObservationIgnored private let viewerCache = JSONFileStore<Viewer>(name: "viewer.json")

    var session: Session? {
        if case .signedIn(let session) = auth { session } else { nil }
    }

    #if DEBUG
    /// The demo snapshots' session with made-up data, without asking the GitHub CLI for a token.
    func showDemo(_ session: Session) {
        auth = .signedIn(session)
    }
    #endif

    // MARK: - Lifecycle

    func start() {
        startSnoozeTimer()
        connect()
    }

    /// Reads the GitHub CLI's token and starts a session with it. Also used to pick up a new
    /// login after `gh auth login` / `gh auth switch`.
    func connect() {
        guard !isConnecting else { return }
        isConnecting = true
        if session == nil { auth = .checking }
        Task {
            defer { isConnecting = false }
            do {
                let token = try await GitHubCLI.token()
                guard token != activeToken || session == nil else { return }
                await activate(token: token)
            } catch let error as GitHubCLI.TokenError {
                disconnect(error)
            } catch {
                disconnect(.failed(error.localizedDescription))
            }
        }
    }

    /// GitHub rejected the token: maybe the CLI logged in again since. If the CLI still hands out
    /// the rejected token, ask the user to refresh the CLI login.
    private func handleUnauthorized(rejected: String) {
        // Both stores report the same 401, and a replaced session can report late: react once,
        // and only while the rejected token is still the active one.
        guard rejected == activeToken, !isConnecting else { return }
        Log.error(.auth, "GitHub rejected the token, asking the GitHub CLI for a new one")
        isConnecting = true
        Task {
            defer { isConnecting = false }
            if let token = try? await GitHubCLI.token(), token != rejected {
                await activate(token: token)
            } else {
                disconnect(.failed("GitHub rejected the GitHub CLI's token. Run `gh auth login` again, then check again."))
            }
        }
    }

    private func disconnect(_ reason: GitHubCLI.TokenError) {
        Log.error(.auth, "Signed out: \(reason.localizedDescription)")
        session?.stop()
        activeToken = nil
        auth = .signedOut(reason)
    }

    func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    /// Before the panel shows: it opens with everything that arrived, then holds still while open.
    func panelWillOpen() {
        session?.holdOrder(true)
    }

    /// Without the panel there's no Undo button: pending actions go through.
    func panelDidClose() {
        session?.holdOrder(false)
        undo.commit()
    }

    func panelDidOpen() {
        panelOpenCount += 1
        if session == nil {
            connect() // the user may have just run `gh auth login`
        }
        session?.refreshIfStale()
    }

    // MARK: - Menu bar

    var menuBarState: MenuBarState {
        guard let session else { return MenuBarState() }
        let threads = session.inbox.threads.filter(isVisible)
        let reviews = session.pullRequests.reviewRequests.filter(isVisible(review:))
        let newRequests = ReviewRequestSignal.unseenCount(
            threads: threads, waiting: reviews, searchedAt: session.pullRequests.lastUpdated
        )
        return MenuBarState(
            unread: threads.count(where: \.unread),
            pendingReviews: reviews.count,
            newReviewRequests: newRequests,
            isSignedIn: true
        )
    }

    /// Inbox threads that aren't snoozed and aren't the notification of a dismissed review request.
    func isVisible(_ thread: NotificationThread) -> Bool {
        !snoozes.isSnoozed(thread) && !dismissedReviews.hides(thread)
    }

    func isVisible(review pullRequest: PullRequestSummary) -> Bool {
        !snoozes.isSnoozed(review: pullRequest) && !dismissedReviews.contains(pullRequest)
    }

    // MARK: - Actions shared by panel, keyboard and banners

    /// Opens the thread in the browser. It stays in the list, without its highlight, until it's marked read.
    func open(_ thread: NotificationThread) {
        guard let session else { return }
        Task {
            let url = await session.inbox.browserURL(for: thread)
            NSWorkspace.shared.open(url)
            await session.inbox.markOpened([thread.id])
        }
    }

    /// Returns false when the thread isn't in the inbox (anymore).
    @discardableResult
    func openThread(id: String) -> Bool {
        guard let thread = session?.inbox.thread(id: id) else { return false }
        open(thread)
        return true
    }

    /// The checkmark: takes threads out of the inbox with a few seconds to take it back; GitHub hears
    /// about it after (read and done).
    func markRead(_ ids: [String]) {
        guard let inbox = session?.inbox, let pending = inbox.markReadLater(ids) else { return }
        undo.offer(UndoCenter.Action(
            title: pending.count == 1 ? "Marked as read" : "\(pending.count) marked as read",
            icon: .read,
            undo: { inbox.undo(pending) },
            commit: { await inbox.commit(pending) }
        ))
    }

    func snooze(_ thread: NotificationThread, option: SnoozeOption) {
        let until = option.date(from: .now)
        Log.info(.actions, "Snoozed thread \(thread.id) (\(thread.logName)) until \(until.formatted())")
        snoozes.snooze(thread, until: until)
        startSnoozeTimer()
        offerUndoForSnooze(key: SnoozeStore.key(for: thread), until: until)
    }

    func snooze(review pullRequest: PullRequestSummary, option: SnoozeOption) {
        let until = option.date(from: .now)
        let related = session?.inbox.threads(for: pullRequest).first
        Log.info(.actions, "Snoozed review request \(pullRequest.subjectKey) until \(until.formatted())")
        snoozes.snooze(review: pullRequest, until: until, relatedThread: related)
        startSnoozeTimer()
        offerUndoForSnooze(key: SnoozeStore.key(forReview: pullRequest), until: until)
    }

    private func offerUndoForSnooze(key: String, until: Date) {
        undo.offer(UndoCenter.Action(
            title: "Snoozed until \(until.formatted(.dateTime.weekday(.abbreviated).hour().minute()))",
            icon: .snooze,
            undo: { [snoozes] in snoozes.unsnooze(key: key) },
            commit: {}
        ))
    }

    func unsnooze(key: String) {
        Log.info(.actions, "Unsnoozed \(key)")
        snoozes.unsnooze(key: key)
    }

    /// Hides a review request you don't plan to act on and marks its notification read.
    func dismiss(review pullRequest: PullRequestSummary) {
        dismissReviewRequest(DismissedReview(
            title: pullRequest.title, repository: pullRequest.repository, number: pullRequest.number, dismissedAt: .now
        ))
    }

    /// The same, from the review request's notification in the Inbox.
    func dismissReviewRequest(of thread: NotificationThread) {
        guard let number = thread.number else { return }
        dismissReviewRequest(DismissedReview(
            title: thread.subject.title, repository: thread.repository.fullName, number: number, dismissedAt: .now
        ))
    }

    func restore(dismissedReview key: String) {
        Log.info(.actions, "Showing dismissed review request \(key) again")
        dismissedReviews.restore(key: key)
    }

    /// Takes a dismissed review off the "Snoozed & dismissed" list; it stays hidden.
    func unlist(dismissedReview key: String) {
        Log.info(.actions, "Took dismissed review request \(key) off the list")
        dismissedReviews.unlist(key: key)
    }

    private func dismissReviewRequest(_ review: DismissedReview) {
        Log.info(.actions, "Dismissed review request \(review.subjectKey)")
        dismissedReviews.dismiss(review)
        guard let session else { return }
        if let pullRequest = session.pullRequests.allReviewRequests.first(where: { $0.subjectKey == review.subjectKey }) {
            snoozes.unsnooze(key: SnoozeStore.key(forReview: pullRequest))
        }
        let notifications = session.inbox.allThreads.filter { $0.subjectKey == review.subjectKey && $0.reason == .reviewRequested }
        let inbox = session.inbox
        let pending = inbox.markReadLater(notifications.map(\.id))
        undo.offer(UndoCenter.Action(
            title: "Review request dismissed",
            icon: .dismiss,
            undo: { [dismissedReviews] in
                dismissedReviews.restore(key: review.subjectKey)
                if let pending { inbox.undo(pending) }
            },
            commit: {
                if let pending { await inbox.commit(pending) }
            }
        ))
    }

    // MARK: - Private

    private func activate(token: String) async {
        let client = GitHubClient(token: token)
        let previousViewer = viewerCache.load()
        let viewer: Viewer
        do {
            viewer = try await NotificationsAPI(client: client).viewer()
            viewerCache.save(viewer)
        } catch GitHubError.unauthorized {
            disconnect(.failed("GitHub rejected the GitHub CLI's token. Run `gh auth login` again, then check again."))
            return
        } catch {
            // Offline at launch: keep going with the cached identity, polling recovers later.
            guard let previousViewer else {
                disconnect(.failed(error.localizedDescription))
                return
            }
            Log.info(.auth, "Couldn't reach GitHub (\(error.localizedDescription)), going on as \(previousViewer.login) from the cache")
            viewer = previousViewer
        }
        if let previousViewer, previousViewer.login != viewer.login {
            banners.reset() // different account: don't announce its whole inbox
        }

        session?.stop()
        let session = Session(client: client, viewer: viewer)
        let onUnauthorized: () -> Void = { [weak self] in
            self?.handleUnauthorized(rejected: token)
        }
        session.inbox.onUnauthorized = onUnauthorized
        session.pullRequests.onUnauthorized = onUnauthorized
        session.pullRequests.onUpdate = { [weak self, weak session] in
            guard let self, let pullRequests = session?.pullRequests else { return }
            // With requests left unfetched, forgetting their dismissal would bring them back, and they'd
            // look like they left.
            if pullRequests.hasAllReviewRequests {
                dismissedReviews.prune(keeping: pullRequests.allReviewRequests)
                pastReviewRequests.update(requested: pullRequests.allReviewRequests, viewer: viewer.login) { [dismissedReviews] in
                    dismissedReviews.entries[$0.subjectKey]?.dismissedAt
                }
            }
        }
        session.pullRequests.leftReviewRequests = { [pastReviewRequests] in pastReviewRequests.left }
        session.inbox.onUpdate = { [weak self, weak session] threads in
            guard let self, let session else { return }
            snoozes.prune(threads: threads)
            // A review request arrived after the last search: search now, not in up to 3 minutes,
            // so the Reviews tab and the menu bar catch up with the notification.
            if ReviewRequestSignal.needsSearch(threads: threads, searchedAt: session.pullRequests.lastUpdated) {
                Task { await session.pullRequests.refresh() }
            }
            guard bannersEnabled else { return }
            banners.process(
                threads: threads,
                details: session.inbox.details,
                viewer: viewer.login,
                reasons: settings.bannerReasons,
                isSnoozed: { !self.isVisible($0) }
            )
        }
        Log.info(.auth, "Signed in as \(viewer.login)")
        activeToken = token
        auth = .signedIn(session)
        session.start()
        if bannersEnabled {
            banners.requestAuthorization()
        }
    }

    private var bannersEnabled: Bool {
        #if DEBUG
        DebugSnapshot.outputDirectory == nil && !ScrollBenchmark.isRequested
        #else
        true
        #endif
    }

    /// Wakes snoozed items on time: pruning mutates the store, which re-renders lists and the icon.
    private func startSnoozeTimer() {
        snoozeTimer?.cancel()
        snoozeTimer = Task { [snoozes] in
            while !Task.isCancelled {
                snoozes.prune()
                let next = snoozes.nextWakeDate.map { max($0.timeIntervalSinceNow, 1) } ?? 3600
                try? await Task.sleep(for: .seconds(min(next + 1, 3600)))
            }
        }
    }
}
