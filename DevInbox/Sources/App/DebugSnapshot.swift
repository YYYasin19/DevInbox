#if DEBUG
import AppKit
import SwiftUI

/// `DevInbox --snapshot <dir>` renders each panel tab to PNG once data has loaded, then quits.
/// Used to check layouts against real data without clicking through the UI.
/// Each appearance gets its own subfolder (`light/`, `dark/`).
enum DebugSnapshot {
    static var outputDirectory: URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count else { return nil }
        return URL(filePath: arguments[index + 1], directoryHint: .isDirectory)
    }

    static func run(model: AppModel, into directory: URL) {
        Task {
            for _ in 0..<120 {
                if let session = model.session,
                   session.inbox.lastUpdated != nil,
                   session.pullRequests.lastUpdated != nil,
                   session.pullRequests.historyUpdated != nil,
                   !session.inbox.isRefreshing { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
            let appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]
            for (name, appearance) in appearances {
                NSApp.appearance = NSAppearance(named: appearance)
                await renderAll(model: model, into: directory.appending(path: name, directoryHint: .isDirectory))
            }

            print("menuBarState:", model.menuBarState)
            if let session = model.session {
                let details = session.inbox.details
                let people = session.inbox.threads.filter {
                    InboxFilter.isFromPerson(details[$0.id], overrides: model.settings.actorOverrides)
                }
                let finished = session.inbox.threads.filter { InboxFilter.isFinished(details[$0.id]) }
                let botLogins = Set(session.inbox.threads.compactMap { details[$0.id]?.latestEvent?.actor }.filter(\.isBot).map(\.login))
                print("filters: people", people.count, "bots", session.inbox.threads.count - people.count,
                      "closed", finished.count, "bot actors:", botLogins.sorted())
            }
            if let session = model.session {
                print("threads:", session.inbox.threads.count, "details:", session.inbox.details.count,
                      "reviews:", session.pullRequests.reviewRequests.count, "history:", session.pullRequests.history.count,
                      "authored:", session.pullRequests.authored.count,
                      "stacks:", session.pullRequests.stacks.count, "restricted:", session.restrictedOrganizations,
                      "errors:", String(describing: session.inbox.error), String(describing: session.pullRequests.error))
            }
            NSApp.terminate(nil)
        }
    }

    private static func renderAll(model: AppModel, into directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: PanelController.size.width, height: PanelController.size.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let hostingView = NSHostingView(rootView: PanelRootView(model: model))
        window.contentView = hostingView
        window.orderFrontRegardless()

        var shots: [(String, () -> Void)] = PanelTab.allCases.map { tab in
            (tab.rawValue, { model.isShowingSnoozed = false; model.selectedTab = tab })
        }
        let originalGrouping = model.settings.inboxGrouping
        let originalDateFormat = model.settings.dateFormat
        let originalCollapsed = model.settings.collapsedRepositories
        let originalActorFilter = model.settings.actorFilter
        let originalFinishedOnly = model.settings.finishedOnly
        let originalShowsReviewHistory = model.settings.showsReviewHistory
        shots.append(("inbox-chronological", {
            model.selectedTab = .inbox
            model.settings.inboxGrouping = .chronological
        }))
        // Grouped, and scrolled so a repository header is pinned over the rows passing under it.
        shots.append(("inbox-by-repo", {
            model.settings.inboxGrouping = .repository
            model.settings.collapsedRepositories = []
        }))
        shots.append(("inbox-by-repo-scrolled", {}))
        shots.append(("reviews-european", {
            model.settings.collapsedRepositories = originalCollapsed
            model.settings.inboxGrouping = originalGrouping
            model.selectedTab = .reviews
            model.settings.dateFormat = .european
        }))
        shots.append(("reviews-history", {
            model.settings.dateFormat = originalDateFormat
            model.settings.showsReviewHistory = true
        }))
        shots.append(("inbox-collapsed", {
            model.settings.showsReviewHistory = originalShowsReviewHistory
            model.settings.dateFormat = originalDateFormat
            model.selectedTab = .inbox
            // The repository with the most notifications collapsed, to show both states.
            let counts = Dictionary(grouping: model.session?.inbox.threads ?? [], by: \.repository.fullName).mapValues(\.count)
            model.settings.collapsedRepositories = Set([counts.max { $0.value < $1.value }?.key].compactMap { $0 })
        }))
        for filter in [ActorFilter.people, .bots] {
            shots.append(("inbox-\(filter.rawValue)", {
                model.settings.collapsedRepositories = []
                model.settings.inboxGrouping = .chronological
                model.settings.actorFilter = filter
            }))
        }
        shots.append(("inbox-closed", {
            model.settings.actorFilter = .all
            model.settings.finishedOnly = true
        }))
        shots.append(("inbox-new", {
            model.settings.finishedOnly = originalFinishedOnly
            model.settings.collapsedRepositories = []
            model.session?.inbox.holdBack(3)
            model.undo.offer(UndoCenter.Action(title: "12 marked as read", icon: .read, undo: {}, commit: {}))
        }))
        shots.append(("inbox-all-collapsed", {
            model.session?.inbox.showAll()
            model.undo.commit()
            model.settings.inboxGrouping = originalGrouping
            model.settings.collapsedRepositories = Set(model.session?.inbox.threads.map(\.repository.fullName) ?? [])
        }))
        for (name, configure) in shots {
            configure()
            try? await Task.sleep(for: .seconds(2.5)) // let avatars load
            hostingView.layoutSubtreeIfNeeded()
            if name.hasSuffix("-scrolled"), let scrollView = firstScrollView(in: hostingView) {
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: 140))
                scrollView.reflectScrolledClipView(scrollView.contentView)
                hostingView.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .seconds(0.5))
            }
            guard let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else { continue }
            hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: directory.appending(path: "\(name).png"))
        }
        model.settings.inboxGrouping = originalGrouping
        model.settings.dateFormat = originalDateFormat
        model.settings.collapsedRepositories = originalCollapsed
        model.settings.actorFilter = originalActorFilter
        model.settings.finishedOnly = originalFinishedOnly
        model.selectedTab = .inbox
        window.orderOut(nil)

        if let session = model.session {
            await render(MyPullRequestsView(model: model, session: session), size: NSSize(width: 460, height: 3400), to: directory.appending(path: "myPullRequests-all.png"))
            model.settings.showsReviewHistory = true
            await render(ReviewsView(model: model, session: session), size: NSSize(width: 460, height: 3400), to: directory.appending(path: "reviews-all.png"))
            model.settings.showsReviewHistory = originalShowsReviewHistory
            // With no reviews waiting, the history says so above itself.
            let alone = ReviewsView.historyEntries(
                Array(session.pullRequests.history.prefix(3)), isAloneInList: true, isExpanded: true, onToggle: {}, onOpen: { _ in }
            )
            await render(list([.space("top", height: 4)] + alone), size: NSSize(width: 460, height: 340), to: directory.appending(path: "reviews-history-alone.png"))
        }
        await render(SettingsView(model: model), size: NSSize(width: 460, height: 640), to: directory.appending(path: "settings.png"))
        let signIn = VStack(spacing: 24) {
            SignInInstructions(reason: .notInstalled, model: model)
            Divider()
            SignInInstructions(reason: .notLoggedIn, model: model)
            Divider()
            SignInInstructions(reason: .failed("GitHub rejected the GitHub CLI's token. Run `gh auth login` again, then check again."), model: model)
        }.padding(.vertical)
        await render(signIn, size: NSSize(width: 460, height: 560), to: directory.appending(path: "sign-in.png"))
        await render(MenuBarPreview(), size: NSSize(width: 460, height: 200), to: directory.appending(path: "menu-bar.png"))
        await render(SnoozedListView(model: model), size: NSSize(width: 460, height: 360), to: directory.appending(path: "snoozed.png"))
        await render(
            SnoozedListView(model: model, startsWithDismissedShown: true),
            size: NSSize(width: 460, height: 560),
            to: directory.appending(path: "snoozed-expanded.png")
        )
        let states = VStack(spacing: 8) {
            MessageBanner(icon: .offline, tone: .warning, text: GitHubError.offline.localizedDescription)
            MessageBanner(
                icon: .lock, tone: .attention,
                text: "secret-org restricts OAuth apps and hasn't approved the GitHub CLI, so some details are hidden.",
                actionTitle: "Request access", action: {}
            )
            Divider()
            LoadingView().frame(height: 60)
            HStack(alignment: .top, spacing: 12) {
                TooltipBubble(text: "Mark as read — takes it out of the list (R)")
                TooltipBubble(text: "Failing checks:\n• build (macos-26)\n• lint")
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, Theme.Inset.fill)
        await render(states, size: NSSize(width: 460, height: 520), to: directory.appending(path: "states.png"))
        if let session = model.session, let thread = session.inbox.threads.first, let review = session.pullRequests.reviewRequests.first {
            let rows = [
                WorstCase.notification(thread, session.inbox.details[thread.id], viewer: session.viewer.login, showsRepository: true, isSelected: true),
                WorstCase.review(review, viewer: session.viewer.login, isSelected: true),
            ]
            await render(list(rows.map(\.entry), pinned: Set(rows.map(\.entry.id))), size: NSSize(width: 460, height: 420), to: directory.appending(path: "rows-selected.png"))
        }
        await renderWorstCase(WorstCase.inbox, to: directory.appending(path: "worst-case-inbox.png"))
        await renderWorstCase(WorstCase.reviews, to: directory.appending(path: "worst-case-reviews.png"))
        await renderWorstCase(WorstCase.myPullRequests, to: directory.appending(path: "worst-case-my-prs.png"))
        await renderWorstCase(WorstCase.history, to: directory.appending(path: "worst-case-history.png"))
    }

    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        return view.subviews.lazy.compactMap(firstScrollView).first
    }

    /// Renders a worst-case list as tall as it needs to be.
    private static func renderWorstCase(_ items: [WorstCase.Item], to url: URL) async {
        let entries = [ListEntry.space("top", height: 4)] + items.map(\.entry) + [.space("bottom", height: 4)]
        // Separators between two rows, as the list adds them.
        let separators = zip(entries, entries.dropFirst()).count { $0.isRow && $1.isRow }
        let height = entries.reduce(0) { $0 + $1.height } + CGFloat(separators)
        let pinned = Set(items.filter(\.isSelected).map(\.entry.id))
        await render(list(entries, pinned: pinned), size: NSSize(width: 460, height: height), to: url)
    }

    /// A list like the panel's, with `pinned` rows highlighted and showing their buttons.
    private static func list(_ entries: [ListEntry], pinned: Set<String> = []) -> some View {
        let selection = ListSelection()
        selection.pinnedIDs = pinned
        return ListHost(entries: entries, selection: selection)
    }

    private static func render(_ view: some View, size: NSSize, to url: URL) async {
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let hostingView = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor)))
        window.contentView = hostingView
        window.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(2.5))
        hostingView.layoutSubtreeIfNeeded()
        guard let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else { return }
        hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}

/// The worst realistic value for every field the rows show (see the break-ui skill). Logins and
/// organizations use GitHub's 39-character maximum, repository names its 100-character maximum,
/// and the inbox fetches at most 200 notifications (4 pages of 50).
private enum WorstCase {
    struct Item {
        let entry: ListEntry
        var isSelected = false

        static func caption(_ text: String) -> Item {
            Item(entry: .note(UUID().uuidString, NoteModel(
                text: text, font: .monospacedSystemFont(ofSize: 10, weight: .regular),
                leading: Theme.Inset.content, top: 12, bottom: 0
            )))
        }
    }

    static let viewer = "aleksandra-wisniewska-kowalczyk-designs"
    static let longLogin = "christopher-alexander-montgomery-the3rd"
    static let longRepository = "northwind-industries-holdings-platforms/customer-feedback-from-enterprise-onboarding-and-self-serve-signup-analytics-pipeline-infrastructure"
    static let team = "Platform Infrastructure & Developer Experience (EMEA)"
    static let teamSlug = "platform-infrastructure-developer-experience-emea"
    static let longBranch = "release/2026.10-enterprise-customer-hotfixes"
    static let avatar = URL(string: "https://avatars.githubusercontent.com/u/9919?v=4")
    static let brokenAvatar = URL(string: "https://example.com/avatars/deleted-user.png")
    static let longActor = Actor(login: longLogin, avatarUrl: avatar)
    /// GitHub's launch: the oldest date the API can return.
    static let ancient = Date(timeIntervalSince1970: 1_207_008_000)
    /// A server clock a few days ahead of this Mac's.
    static let future = Date.now.addingTimeInterval(3 * 86_400)
    static let stack = StackInfo(
        entries: (1...12).map { StackInfo.Entry(number: 1_234_555 + $0, state: $0 < 4 ? .merged : .open) },
        position: 12,
        isNative: true
    )
    static let failing = ChecksSummary(state: .failure, failing: (1...12).map { "integration-tests (shard \($0) of 12)" }, pending: [], total: 48)
    static let running = ChecksSummary(state: .pending, failing: [], pending: ["build (macos-26, release)"], total: 3)
    static let passing = ChecksSummary(state: .success, failing: [], pending: [], total: 48)
    static let changesRequested = [PullRequestSummary.Review(author: longActor, state: "CHANGES_REQUESTED")]
    /// As many as DevInbox fetches: by people and a bot, around the author's own replies.
    static let comments = (1...50).map { index in
        let actor = switch index % 4 {
        case 0: longActor
        case 1: Actor(login: "github-actions", avatarUrl: nil, typename: "Bot")
        default: Actor(login: "nour-alhuda", avatarUrl: brokenAvatar)
        }
        return TimelineEvent(kind: .commented, actor: actor, date: .now.addingTimeInterval(Double(index - 60) * 600), url: nil)
    }

    enum Title {
        static let url = "Fix redirect loop on https://example.com/workspaces/acme/projects/q3-launch/docs/9f8e7d6c5b4a?tab=comments&filter=unresolved"
        static let long = "Migrate notification preferences from the legacy REST endpoints to GraphQL and backfill missing audit events for enterprise tenants"
        static let german = "Benachrichtigungseinstellungen: Datenschutzgrundverordnungskonformitätsprüfung ergänzen"
        static let arabic = "إصلاح خطأ تسجيل الدخول عند استخدام المصادقة الثنائية"
        static let cjk = "修复使用双重身份验证时登录失败以及会话超时的问题"
        static let emoji = "🚀 Release v2.0 — 👩🏽‍💻 new onboarding flow 🎉🎉 and the 🦊 mascot"
    }

    // MARK: Lists

    static var inbox: [Item] {
        let repository = (1...200).map { thread("Notification \($0)", reason: .subscribed) }
        return [
            .caption("By repo: 39-char org, 100-char repo, 200 unread"),
            header(repository),
            notification(thread(Title.url, reason: .reviewRequested), details(.reviewRequested, actor: longActor, target: teamSlug)),
            notification(thread(Title.german, reason: .reviewRequested), details(.closed, actor: longActor, state: .closed)),
            notification(thread("x", type: .issue, reason: .mention), details(.closed, actor: nil, state: .closed)),
            notification(thread(Title.arabic, reason: .teamMention), details(.commented, actor: Actor(login: "nour-alhuda", avatarUrl: brokenAvatar))),
            notification(thread(Title.cjk, type: .issue, reason: .subscribed, unread: false, updatedAt: ancient), nil),
            notification(thread("Critical: prototype pollution in lodash.merge via a crafted __proto__ payload", type: .dependabotAlerts, number: nil, reason: .securityAlert), nil),
            notification(thread(Title.german, reason: .assign), details(.changesRequested, actor: longActor), isSelected: true),
            notification(thread(Title.emoji, reason: .reviewRequested), details(.approved, actor: Actor(login: "jo", avatarUrl: nil), date: future)),
            .caption("Latest: repository shown"),
            notification(thread(Title.long, reason: .reviewRequested), details(.committed, actor: longActor), showsRepository: true),
            notification(thread("v12.0.0-rc.1+build.20261010.enterprise-lts", type: .release, number: nil, reason: .subscribed, unread: false), nil, showsRepository: true),
            notification(thread("a", number: 1, reason: .author, repository: "jo/a"), details(.merged, actor: Actor(login: "j", avatarUrl: nil), state: .merged), showsRepository: true),
            notification(thread("CI: build-and-test (macos-26, release) failed on main", type: .checkSuite, number: nil, reason: .ciActivity), nil, showsRepository: true),
            notification(thread(Title.url, type: .issue, reason: .manual, unread: false), details(.assigned, actor: longActor, target: longLogin), showsRepository: true, isSelected: true),
        ]
    }

    static var reviews: [Item] {
        let viaTeam: [PullRequestSummary.RequestedReviewer] = [.team(name: team, slug: teamSlug)]
        return [
            review(pullRequest(Title.url, additions: 123_456, deletions: 98_765, requestedReviewers: viaTeam, checks: failing, requestedAt: .now.addingTimeInterval(-600), isTeamRequest: true), stack: stack),
            review(pullRequest("x", number: 1, repository: "jo/a", additions: 0, deletions: 0, author: nil, requestedAt: future)),
            review(pullRequest(Title.long, isDraft: true, checks: running)),
            review(pullRequest(Title.arabic, author: Actor(login: "nour-alhuda", avatarUrl: brokenAvatar), checks: passing, requestedAt: ancient)),
            review(pullRequest(Title.cjk, requestedReviewers: viaTeam, isTeamRequest: true)),
            review(pullRequest(Title.emoji, author: Actor(login: "dependabot", avatarUrl: nil), checks: passing), stack: stack),
            review(pullRequest(Title.german, additions: 123_456, deletions: 98_765, checks: failing), isSelected: true),
        ]
    }

    static var myPullRequests: [Item] {
        [
            myPullRequest(pullRequest(Title.url, reviewDecision: .changesRequested, reviews: changesRequested, checks: failing, mergeable: "CONFLICTING", mergeStateStatus: "DIRTY", unresolvedThreads: 7, comments: comments), stack: stack),
            myPullRequest(pullRequest(Title.long, baseRefName: longBranch, reviewDecision: .changesRequested, reviews: changesRequested, checks: failing, mergeStateStatus: "BEHIND", comments: comments)),
            myPullRequest(pullRequest(Title.cjk, updatedAt: ancient, checks: running, mergeStateStatus: "BEHIND", unresolvedThreads: 1)),
            myPullRequest(pullRequest(Title.german, isDraft: true, reviewDecision: nil, reviews: [.init(author: longActor, state: "APPROVED")], checks: running), stack: stack),
            myPullRequest(pullRequest("x", number: 1, repository: "jo/a", updatedAt: future, reviewDecision: nil, mergeStateStatus: "UNKNOWN")),
            myPullRequest(pullRequest(Title.arabic, reviewDecision: .approved, checks: passing, mergeStateStatus: "CLEAN", comments: [TimelineEvent(kind: .commented, actor: nil, date: ancient, url: nil)])),
            myPullRequest(pullRequest(Title.emoji, isDraft: true)),
            myPullRequest(pullRequest(Title.long, reviewDecision: .changesRequested, reviews: changesRequested, checks: failing, mergeStateStatus: "BEHIND", unresolvedThreads: 12), isSelected: true),
        ]
    }

    static var history: [Item] {
        let merged = [
            TimelineEvent(kind: .committed, actor: longActor, date: .now.addingTimeInterval(-9_000), url: nil),
            TimelineEvent(kind: .committed, actor: longActor, date: .now.addingTimeInterval(-8_000), url: nil),
            TimelineEvent(kind: .committed, actor: nil, date: .now.addingTimeInterval(-7_500), url: nil),
            TimelineEvent(kind: .replied, actor: longActor, date: .now.addingTimeInterval(-7_000), url: nil),
            TimelineEvent(kind: .changesRequested, actor: Actor(login: "jo", avatarUrl: nil), date: .now.addingTimeInterval(-6_000), url: nil),
            TimelineEvent(kind: .approved, actor: longActor, date: .now.addingTimeInterval(-5_000), url: nil),
            TimelineEvent(kind: .merged, actor: longActor, date: .now.addingTimeInterval(-4_000), url: nil),
        ] + (1...1_284).map { TimelineEvent(kind: .commented, actor: longActor, date: .now.addingTimeInterval(Double(-3_900 + $0)), url: nil) }
        return [
            .caption("Merged with everything, open with a force-push, closed, dismissed, ended"),
            reviewed(reviewedPullRequest(Title.url, state: .merged, involvement: .changesRequested, events: merged, hasNewCommits: true, threads: .init(resolved: 7, total: 12))),
            reviewed(reviewedPullRequest(Title.long, state: .open, involvement: .approved, events: [TimelineEvent(kind: .forcePushed, actor: longActor, date: .now.addingTimeInterval(-600), url: nil)], hasNewCommits: true, threads: .init(resolved: 12, total: 12)), isSelected: true),
            reviewed(reviewedPullRequest(Title.arabic, state: .closed, involvement: .reviewDismissed, events: [TimelineEvent(kind: .closed, actor: longActor, date: future, url: nil)])),
            reviewed(reviewedPullRequest("x", number: 1, repository: "jo/a", state: .draft, involvement: .commented, author: nil, since: ancient)),
            reviewed(reviewedPullRequest(Title.cjk, state: .open, involvement: .requestDismissed, events: [TimelineEvent(kind: .reviewed, actor: Actor(login: "nour-alhuda", avatarUrl: brokenAvatar), date: .now, url: nil)])),
            reviewed(reviewedPullRequest(Title.german, state: .merged, involvement: .requestEnded, events: [TimelineEvent(kind: .merged, actor: nil, date: .now, url: nil)])),
        ]
    }

    // MARK: Builders

    static func header(_ threads: [NotificationThread]) -> Item {
        let model = RepositoryHeaderModel(
            repository: threads[0].repository, count: threads.count, newCount: threads.count(where: \.unread), isCollapsed: false,
            onToggle: { _ in }, markRead: RowButton(.read, help: "") {}
        )
        return Item(entry: ListEntry(id: UUID().uuidString, kind: .header(floats: true), height: RepositoryHeaderModel.height, value: 0) { _ in
            .repositoryHeader(model)
        })
    }

    static func notification(
        _ thread: NotificationThread, _ details: SubjectDetails?, viewer: String = viewer, showsRepository: Bool = false, isSelected: Bool = false
    ) -> Item {
        let row = NotificationRow(
            thread: thread, details: details, viewer: viewer, showsRepository: showsRepository,
            canDismissReviewRequest: thread.reason == .reviewRequested && !InboxFilter.isFinished(details)
        )
        let actions = NotificationRow.Actions(onOpen: {}, onMarkRead: {}, onSnooze: { _ in })
        return Item(entry: ListEntry(id: UUID().uuidString, kind: .row(isSelectable: true), height: RowModel.height, value: row) {
            .row(row.model(in: $0, actions: actions))
        }, isSelected: isSelected)
    }

    static func review(_ pullRequest: PullRequestSummary, viewer: String = viewer, stack: StackInfo? = nil, isSelected: Bool = false) -> Item {
        let row = ReviewRow(pullRequest: pullRequest, stack: stack, viewer: viewer)
        let actions = ReviewRow.Actions(onOpen: {}, onSnooze: { _ in }, onDismiss: {}, onCopyBranch: {})
        return Item(entry: ListEntry(id: UUID().uuidString, kind: .row(isSelectable: true), height: RowModel.height, value: row) {
            .row(row.model(in: $0, actions: actions))
        }, isSelected: isSelected)
    }

    static func myPullRequest(_ pullRequest: PullRequestSummary, stack: StackInfo? = nil, isSelected: Bool = false) -> Item {
        let row = MyPullRequestRow(pullRequest: pullRequest, stack: stack)
        let actions = MyPullRequestRow.Actions(onOpen: {}, onCopyBranch: {})
        return Item(entry: ListEntry(id: UUID().uuidString, kind: .row(isSelectable: true), height: RowModel.height, value: row) {
            .row(row.model(in: $0, actions: actions))
        }, isSelected: isSelected)
    }

    static func reviewed(_ pullRequest: ReviewedPullRequest, isSelected: Bool = false) -> Item {
        let row = ReviewHistoryRow(pullRequest: pullRequest)
        return Item(entry: ListEntry(id: UUID().uuidString, kind: .row(isSelectable: true), height: RowModel.height, value: row) {
            .row(row.model(in: $0) {})
        }, isSelected: isSelected)
    }

    static func thread(
        _ title: String,
        type: SubjectType = .pullRequest,
        number: Int? = 1_234_567,
        reason: NotificationReason,
        unread: Bool = true,
        updatedAt: Date = .now.addingTimeInterval(-3_600),
        repository: String = longRepository
    ) -> NotificationThread {
        let kind = type == .pullRequest ? "pulls" : "issues"
        return NotificationThread(
            id: UUID().uuidString,
            unread: unread,
            reason: reason,
            updatedAt: updatedAt,
            lastReadAt: nil,
            subject: .init(
                title: title,
                url: number.flatMap { URL(string: "https://api.github.com/repos/\(repository)/\(kind)/\($0)") },
                latestCommentURL: nil,
                type: type
            ),
            repository: .init(
                fullName: repository,
                htmlURL: URL(string: "https://github.com/\(repository)")!,
                owner: .init(login: String(repository.prefix { $0 != "/" }), avatarURL: avatar)
            )
        )
    }

    static func details(
        _ kind: TimelineEvent.Kind,
        actor: Actor?,
        date: Date = .now.addingTimeInterval(-7_200),
        target: String? = nil,
        state: SubjectState = .open
    ) -> SubjectDetails {
        SubjectDetails(state: state, commentCount: 1_284, latestEvent: TimelineEvent(kind: kind, actor: actor, date: date, url: nil, target: target))
    }

    static func reviewedPullRequest(
        _ title: String,
        number: Int = 1_234_567,
        repository: String = longRepository,
        state: SubjectState,
        involvement: ReviewedPullRequest.Involvement,
        author: Actor? = longActor,
        since: Date = .now.addingTimeInterval(-10_000),
        events: [TimelineEvent] = [],
        hasNewCommits: Bool = false,
        threads: ReviewedPullRequest.ThreadCount? = nil
    ) -> ReviewedPullRequest {
        let finish = events.last { $0.kind == .merged || $0.kind == .closed }
        return ReviewedPullRequest(
            id: UUID().uuidString,
            number: number,
            title: title,
            url: URL(string: "https://github.com/\(repository)/pull/\(number)")!,
            repository: repository,
            author: author,
            state: state,
            finishedBy: finish?.actor,
            finishedAt: finish?.date,
            involvement: involvement,
            since: since,
            events: events,
            hasNewCommits: hasNewCommits,
            yourThreads: threads
        )
    }

    static func pullRequest(
        _ title: String,
        number: Int = 1_234_567,
        repository: String = longRepository,
        isDraft: Bool = false,
        updatedAt: Date = .now.addingTimeInterval(-5_400),
        additions: Int = 1_284,
        deletions: Int = 312,
        author: Actor? = longActor,
        baseRefName: String = "main",
        reviewDecision: PullRequestSummary.ReviewDecision? = .reviewRequired,
        reviews: [PullRequestSummary.Review] = [],
        requestedReviewers: [PullRequestSummary.RequestedReviewer] = [],
        checks: ChecksSummary? = nil,
        mergeable: String = "MERGEABLE",
        mergeStateStatus: String = "BLOCKED",
        unresolvedThreads: Int = 0,
        comments: [TimelineEvent] = [],
        requestedAt: Date? = nil,
        isTeamRequest: Bool = false
    ) -> PullRequestSummary {
        let requests = requestedAt.map {
            [PullRequestSummary.ReviewRequestEvent(date: $0, reviewer: isTeamRequest ? teamSlug : viewer, isTeam: isTeamRequest)]
        }
        return PullRequestSummary(
            id: UUID().uuidString,
            number: number,
            title: title,
            url: URL(string: "https://github.com/\(repository)/pull/\(number)")!,
            repository: repository,
            isDraft: isDraft,
            createdAt: ancient,
            updatedAt: updatedAt,
            additions: additions,
            deletions: deletions,
            author: author,
            baseRefName: baseRefName,
            headRefName: "feature/\(number)",
            isCrossRepository: false,
            reviewDecision: reviewDecision,
            reviews: reviews,
            requestedReviewers: requestedReviewers,
            checks: checks,
            mergeable: mergeable,
            mergeStateStatus: mergeStateStatus,
            unresolvedThreads: unresolvedThreads,
            comments: comments,
            reviewRequestEvents: requests ?? []
        )
    }
}

/// The status item pill as the menu bar would tint it, on light, dark and busy backgrounds.
struct MenuBarPreview: View {
    private let variants: [(unread: Int, reviews: Int, dot: Bool)] = [(16, 0, false), (16, 9, true), (0, 3, true), (1284, 12, false)]

    var body: some View {
        VStack(spacing: 0) {
            bar(background: AnyShapeStyle(Color(white: 0.93)), tint: .black)
            bar(background: AnyShapeStyle(Color(white: 0.12)), tint: .white)
            bar(background: AnyShapeStyle(LinearGradient(colors: [.red, .orange, .red, .teal, .red], startPoint: .leading, endPoint: .trailing)), tint: .white)
        }
    }

    private func bar(background: AnyShapeStyle, tint: Color) -> some View {
        HStack(spacing: 18) {
            ForEach(variants.indices, id: \.self) { index in
                let variant = variants[index]
                if let image = StatusPill.image(unread: variant.unread, reviews: variant.reviews, scale: 2) {
                    Image(nsImage: image)
                        .renderingMode(.template)
                        .foregroundStyle(tint)
                        .overlay(alignment: .topTrailing) {
                            if variant.dot {
                                Circle().fill(.red).frame(width: 9, height: 9)
                                    .overlay(Circle().strokeBorder(tint, lineWidth: 1.5))
                                    .shadow(color: .red.opacity(0.9), radius: 2.5)
                                    .offset(x: 2.5, y: -2.5)
                            }
                        }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 50)
        .background(background)
    }
}

#endif
