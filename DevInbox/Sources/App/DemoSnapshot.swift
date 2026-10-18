#if DEBUG
import AppKit
import SwiftUI

/// `DevInbox --snapshot <dir> --demo` renders the README images from made-up data, then quits:
/// `inbox.png`, `reviews.png` and `my-prs.png`, each also as `-dark.png`, at 2x with the panel's shadow,
/// plus `menu-bar.png`. `--snapshot` alone shows the real account, whose notifications include private
/// repositories, so this mode never signs in or fetches. Its settings come from a domain that's never
/// saved and its files from a scratch directory, so nothing real is shown or changed.
enum DemoSnapshot {
    nonisolated static var isRequested: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--demo") && arguments.contains("--snapshot")
    }

    static var outputDirectory: URL? {
        isRequested ? DebugSnapshot.outputDirectory : nil
    }

    /// Holds the file stores while it runs (see `JSONFileStore.defaultDirectory`) and the avatars.
    nonisolated static var storageDirectory: URL {
        FileManager.default.temporaryDirectory.appending(path: "DevInbox-demo", directoryHint: .isDirectory)
    }

    static func run(into directory: URL) {
        let files = FileManager.default
        try? files.removeItem(at: storageDirectory)
        try? files.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        try? files.createDirectory(at: directory, withIntermediateDirectories: true)
        useDemoSettings()
        DemoData.writeAvatars()

        let model = AppModel()
        let session = Session(client: GitHubClient(token: "", transport: NoNetwork()), viewer: DemoData.viewer)
        session.inbox.showDemo(DemoData.threads, details: DemoData.details)
        session.pullRequests.showDemo(
            reviewRequests: DemoData.reviewRequests, authored: DemoData.authored, history: DemoData.history, stacks: DemoData.stacks
        )
        for (thread, until) in DemoData.snoozed {
            model.snoozes.snooze(thread, until: until)
        }
        model.showDemo(session)

        Task {
            for (suffix, appearance) in [("", NSAppearance.Name.aqua), ("-dark", .darkAqua)] {
                NSApp.appearance = NSAppearance(named: appearance)
                for tab in PanelTab.allCases {
                    model.selectedTab = tab
                    await renderPanel(model: model, to: directory.appending(path: "\(fileName(for: tab))\(suffix).png"))
                }
            }
            NSApp.appearance = nil
            await render(MenuBarPreview(), size: NSSize(width: 460, height: 150), to: directory.appending(path: "menu-bar.png"))
            try? files.removeItem(at: storageDirectory)
            NSApp.terminate(nil)
        }
    }

    private static func fileName(for tab: PanelTab) -> String {
        switch tab {
        case .inbox: "inbox"
        case .reviews: "reviews"
        case .myPullRequests: "my-prs"
        }
    }

    /// Puts the demo's settings in the argument domain, which is read first and never saved. They're
    /// set on a scratch `AppSettings` first, in a plist in the storage directory, to get the real keys.
    private static func useDemoSettings() {
        let name = storageDirectory.appending(path: "settings").path(percentEncoded: false)
        guard let scratch = UserDefaults(suiteName: name) else { return }
        let settings = AppSettings(defaults: scratch)
        // Creating `AppSettings` saves the shortcut it read, which here isn't the real one. Only what's
        // set below goes in the argument domain, so the app's own `AppSettings` keeps the real shortcut.
        scratch.removePersistentDomain(forName: name)
        settings.inboxGrouping = .repository
        settings.actorFilter = .all
        settings.finishedOnly = false
        settings.actorOverrides = [:]
        settings.collapsedRepositories = []
        settings.showsReviewHistory = true
        settings.dateFormat = .monthDay
        let values = scratch.persistentDomain(forName: name) ?? [:]

        let standard = UserDefaults.standard
        let arguments = standard.volatileDomain(forName: UserDefaults.argumentDomain)
        standard.removeVolatileDomain(forName: UserDefaults.argumentDomain)
        standard.setVolatileDomain(arguments.merging(values) { $1 }, forName: UserDefaults.argumentDomain)
    }

    // MARK: Rendering

    private static let scale: CGFloat = 2
    /// Room for the shadow around the panel.
    private static let margin: CGFloat = 32

    /// The panel as it opens: a rounded surface on a clear window, with a shadow like the real one's.
    private static func renderPanel(model: AppModel, to url: URL) async {
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: PanelController.size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        let hostingView = NSHostingView(rootView: PanelRootView(model: model))
        window.contentView = hostingView
        window.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(1.5)) // rows redraw once their avatars have loaded
        hostingView.layoutSubtreeIfNeeded()
        let panel = bitmap(of: hostingView)
        window.orderOut(nil)

        let size = NSSize(width: panel.size.width + 2 * margin, height: panel.size.height + 2 * margin)
        let framed = canvas(size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: framed)
        // A wide, soft shadow and a tight one along the edge, like a macOS window's.
        for (blur, offset, opacity) in [(28.0, 10.0, 0.22), (2.0, 0.5, 0.18)] {
            let shadow = NSShadow()
            shadow.shadowBlurRadius = blur
            shadow.shadowOffset = NSSize(width: 0, height: -offset)
            shadow.shadowColor = NSColor.black.withAlphaComponent(opacity)
            shadow.set()
            // Over, not the default copy: copying would wipe the shadow under the transparent corners.
            panel.draw(
                in: NSRect(origin: NSPoint(x: margin, y: margin), size: panel.size), from: .zero,
                operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil
            )
        }
        NSGraphicsContext.restoreGraphicsState()
        write(framed, to: url)
    }

    private static func render(_ view: some View, size: NSSize, to url: URL) async {
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let hostingView = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        window.contentView = hostingView
        window.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(1))
        hostingView.layoutSubtreeIfNeeded()
        write(bitmap(of: hostingView), to: url)
        window.orderOut(nil)
    }

    /// At 2x, whatever the screen's scale.
    private static func bitmap(of view: NSView) -> NSBitmapImageRep {
        let rep = canvas(view.bounds.size)
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    private static func canvas(_ size: NSSize) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!.retagging(with: .sRGB)!
        rep.size = size
        return rep
    }

    private static func write(_ rep: NSBitmapImageRep, to url: URL) {
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("wrote", url.path(percentEncoded: false))
    }
}

/// Anything that still tries to reach GitHub fails, and says so: the demo has to come from `DemoData`.
private nonisolated struct NoNetwork: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        print("demo: blocked \(request.httpMethod ?? "GET") \(request.url?.path() ?? "")")
        throw URLError(.cannotConnectToHost)
    }
}

/// A calm workday at made-up companies: Acme's services and apps, and Northwind's design system.
private enum DemoData {
    /// Half a minute before this minute began: the panel's clock ticks by the minute, so an event
    /// exactly 2 hours before now would show as "1h".
    static let now = Calendar.current.dateInterval(of: .minute, for: .now)!.start.addingTimeInterval(-30)
    static let viewer = Viewer(login: "octo-dev", name: "Octo Dev", avatarURL: avatarURL("octo-dev"))

    static let alice = person("alice")
    static let bob = person("bob")
    static let carol = person("carol")
    static let dave = person("dave")
    static let erin = person("erin")
    static let frank = person("frank")
    static let grace = person("grace")
    static let dependabot = Actor(login: "dependabot", avatarUrl: avatarURL("dependabot"), typename: "Bot")

    static func minutesAgo(_ minutes: Double) -> Date {
        now.addingTimeInterval(-minutes * 60)
    }

    static func hoursAgo(_ hours: Double) -> Date {
        minutesAgo(hours * 60)
    }

    static func daysAgo(_ days: Double) -> Date {
        hoursAgo(days * 24)
    }

    // MARK: Inbox

    static let inbox: [(thread: NotificationThread, details: SubjectDetails?)] = [
        (
            thread("1", "Add rate limiting to the public API", number: 142, in: "acme/api", reason: .mention, unread: true, at: minutesAgo(12)),
            details(.commented, by: bob, at: minutesAgo(12), comments: 6)
        ),
        (
            thread("2", "Retry failed webhooks with exponential backoff", number: 138, in: "acme/api", reason: .reviewRequested, unread: true, at: minutesAgo(26)),
            details(.reviewRequested, by: alice, at: minutesAgo(26), target: viewer.login)
        ),
        (
            thread("3", "Deploy workflow run failed for main branch", type: .checkSuite, in: "acme/api", reason: .ciActivity, unread: false, at: minutesAgo(70)),
            nil
        ),
        (
            thread("4", "Paginate the /invoices endpoint", number: 131, in: "acme/api", reason: .author, unread: false, at: hoursAgo(2)),
            details(.approved, by: carol, at: hoursAgo(2), comments: 3)
        ),
        (
            thread("5", "Dark mode for the billing dashboard", number: 87, in: "acme/web", reason: .author, unread: true, at: minutesAgo(48)),
            details(.changesRequested, by: dave, at: minutesAgo(48), comments: 4)
        ),
        (
            thread("6", "Checkout button doesn't respond in Safari 18", type: .issue, number: 412, in: "acme/web", reason: .assign, unread: true, at: hoursAgo(3)),
            details(.assigned, by: erin, at: hoursAgo(3), target: viewer.login)
        ),
        (
            thread("7", "Spacing tokens on a 4pt grid", number: 56, in: "northwind/design-system", reason: .comment, unread: false, at: hoursAgo(5)),
            details(.merged, by: frank, at: hoursAgo(5), state: .merged, comments: 9)
        ),
        (
            thread("8", "v4.2.0", type: .release, in: "northwind/design-system", reason: .subscribed, unread: false, at: daysAgo(1)),
            nil
        ),
    ]

    static var threads: [NotificationThread] { inbox.map(\.thread) }

    static var details: [String: SubjectDetails] {
        Dictionary(uniqueKeysWithValues: inbox.compactMap { item in item.details.map { (item.thread.id, $0) } })
    }

    /// The moon in the header: two notifications snoozed until tomorrow.
    static var snoozed: [(NotificationThread, Date)] {
        let tomorrow = SnoozeOption.tomorrowMorning.date(from: now)
        return [
            (thread("9", "Flaky test: OrdersControllerTest times out", type: .issue, number: 120, in: "acme/api", reason: .subscribed, unread: true, at: hoursAgo(6)), tomorrow),
            (thread("10", "Haptics for the order confirmation", number: 211, in: "acme/mobile", reason: .mention, unread: true, at: daysAgo(1)), tomorrow),
        ]
    }

    // MARK: Reviews

    static let reviewRequests = [
        pullRequest(
            138, "Retry failed webhooks with exponential backoff", in: "acme/api", by: alice, updated: minutesAgo(20),
            size: (184, 42), checks: passing, requestedReviewers: [.user(person(viewer.login))], requestedAt: minutesAgo(26)
        ),
        pullRequest(
            95, "Lazy-load the charts on the analytics page", in: "acme/web", by: frank, updated: hoursAgo(1),
            size: (312, 198), checks: running, requestedReviewers: [.team(name: "Frontend", slug: "frontend")],
            requestedAt: hoursAgo(2), viaTeam: "frontend"
        ),
        pullRequest(
            91, "Extract the payment client into its own package", in: "acme/web", by: grace, updated: hoursAgo(20),
            size: (96, 310), checks: ChecksSummary(state: .failure, failing: ["e2e (safari)"], pending: [], total: 9),
            requestedReviewers: [.user(person(viewer.login))], requestedAt: daysAgo(1)
        ),
        pullRequest(
            93, "Bump express from 4.19.2 to 4.21.0", in: "acme/web", by: dependabot, updated: daysAgo(3),
            size: (12, 8), checks: passing, requestedReviewers: [.user(person(viewer.login))], requestedAt: daysAgo(3)
        ),
    ]

    static let history = [
        reviewed(
            84, "Cache avatar lookups in the profile service", in: "acme/web", by: bob, state: .open, involvement: .changesRequested,
            since: daysAgo(1),
            events: [
                TimelineEvent(kind: .committed, actor: bob, date: minutesAgo(41), url: nil),
                TimelineEvent(kind: .committed, actor: bob, date: minutesAgo(38), url: nil),
                TimelineEvent(kind: .replied, actor: bob, date: minutesAgo(35), url: nil),
            ],
            hasNewCommits: true, threads: .init(resolved: 2, total: 3)
        ),
        reviewed(
            129, "Add OpenTelemetry tracing to the job workers", in: "acme/api", by: carol, state: .merged, involvement: .approved,
            since: daysAgo(1),
            events: [TimelineEvent(kind: .merged, actor: alice, date: hoursAgo(3), url: nil)],
            threads: .init(resolved: 1, total: 1)
        ),
        reviewed(
            54, "Fix the focus ring on Select in Safari", in: "northwind/design-system", by: erin, state: .open, involvement: .commented,
            since: daysAgo(2),
            events: [
                TimelineEvent(kind: .committed, actor: erin, date: hoursAgo(7), url: nil),
                TimelineEvent(kind: .approved, actor: dave, date: hoursAgo(5), url: nil),
            ],
            hasNewCommits: true
        ),
        reviewed(
            126, "Drop Node 18 from the CI matrix", in: "acme/api", by: dave, state: .closed, involvement: .requestEnded,
            since: daysAgo(3),
            events: [TimelineEvent(kind: .closed, actor: dave, date: daysAgo(2), url: nil)]
        ),
        reviewed(
            205, "Offline mode for the order history", in: "acme/mobile", by: grace, state: .merged, involvement: .approved,
            since: daysAgo(4),
            events: [
                TimelineEvent(kind: .commented, actor: frank, date: daysAgo(3.5), url: nil),
                TimelineEvent(kind: .merged, actor: grace, date: daysAgo(3), url: nil),
            ]
        ),
    ]

    // MARK: My PRs

    static let authored = [
        pullRequest(
            87, "Dark mode for the billing dashboard", in: "acme/web", by: person(viewer.login), updated: minutesAgo(48),
            size: (426, 118), checks: passing, decision: .changesRequested, reviews: [.init(author: dave, state: "CHANGES_REQUESTED")],
            requestedReviewers: [], unresolvedThreads: 2
        ),
        pullRequest(
            131, "Paginate the /invoices endpoint", in: "acme/api", by: person(viewer.login), updated: hoursAgo(2),
            size: (158, 37), checks: passing, decision: .approved, reviews: [.init(author: carol, state: "APPROVED")],
            mergeState: "CLEAN", comments: [comment(carol, hoursAgo(2.2))]
        ),
        pullRequest(
            135, "Stream large CSV exports", in: "acme/api", by: person(viewer.login), updated: hoursAgo(4),
            size: (242, 61), checks: ChecksSummary(state: .failure, failing: ["test (node 22)", "lint"], pending: [], total: 8),
            requestedReviewers: [.user(bob)]
        ),
        pullRequest(
            136, "Resume interrupted CSV exports", in: "acme/api", by: person(viewer.login), updated: hoursAgo(4.5),
            size: (88, 14), checks: running, requestedReviewers: [.user(bob)]
        ),
        pullRequest(
            89, "Usage-based pricing page", in: "acme/web", by: person(viewer.login), updated: hoursAgo(22),
            size: (530, 76), isDraft: true, checks: running, decision: nil, requestedReviewers: []
        ),
        pullRequest(
            57, "Upgrade Storybook to v9", in: "northwind/design-system", by: person(viewer.login), updated: daysAgo(2),
            size: (1204, 988), checks: passing, decision: .approved, reviews: [.init(author: frank, state: "APPROVED")],
            mergeable: "CONFLICTING", mergeState: "DIRTY"
        ),
        pullRequest(
            127, "Document the webhook signature check", in: "acme/api", by: person(viewer.login), updated: daysAgo(3),
            size: (64, 5), checks: passing, requestedReviewers: []
        ),
        pullRequest(
            44, "Move staging to the new cluster", in: "acme/infra", by: person(viewer.login), updated: daysAgo(4),
            size: (73, 51), checks: passing, decision: .approved, reviews: [.init(author: alice, state: "APPROVED")], mergeState: "BEHIND"
        ),
        pullRequest(
            208, "Notification settings screen", in: "acme/mobile", by: person(viewer.login), updated: daysAgo(5),
            size: (311, 22), checks: passing, requestedReviewers: [.user(grace)],
            comments: [comment(erin, daysAgo(5.5)), comment(grace, daysAgo(5.2)), comment(erin, daysAgo(5.1))]
        ),
        pullRequest(
            119, "Spike: GraphQL gateway for the mobile app", in: "acme/api", by: person(viewer.login), updated: daysAgo(6),
            size: (874, 12), isDraft: true, checks: passing, decision: nil, requestedReviewers: []
        ),
    ]

    /// Native stacks: the payment client is the middle of three, the CSV exports are two.
    static var stacks: [String: StackInfo] {
        let payments = [90, 91, 92].map { StackInfo.Entry(number: $0, state: .open) }
        let exports = [135, 136].map { StackInfo.Entry(number: $0, state: .open) }
        return [
            id("acme/web", 91): StackInfo(entries: payments, position: 2, isNative: true),
            id("acme/api", 135): StackInfo(entries: exports, position: 1, isNative: true),
            id("acme/api", 136): StackInfo(entries: exports, position: 2, isNative: true),
        ]
    }

    static let passing = ChecksSummary(state: .success, failing: [], pending: [], total: 9)
    static let running = ChecksSummary(state: .pending, failing: [], pending: ["build", "e2e (chrome)"], total: 9)

    // MARK: Builders

    static func person(_ login: String) -> Actor {
        Actor(login: login, avatarUrl: avatarURL(login), typename: "User")
    }

    static func comment(_ actor: Actor, _ date: Date) -> TimelineEvent {
        TimelineEvent(kind: .commented, actor: actor, date: date, url: nil)
    }

    static func id(_ repository: String, _ number: Int) -> String {
        "demo:\(repository)#\(number)"
    }

    static func thread(
        _ id: String, _ title: String, type: SubjectType = .pullRequest, number: Int? = nil, in repository: String,
        reason: NotificationReason, unread: Bool, at date: Date
    ) -> NotificationThread {
        let kind = type == .pullRequest ? "pulls" : "issues"
        let owner = String(repository.prefix { $0 != "/" })
        return NotificationThread(
            id: id,
            unread: unread,
            reason: reason,
            updatedAt: date,
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
                owner: .init(login: owner, avatarURL: avatarURL(owner))
            )
        )
    }

    static func details(
        _ kind: TimelineEvent.Kind, by actor: Actor, at date: Date, target: String? = nil, state: SubjectState = .open, comments: Int = 0
    ) -> SubjectDetails {
        SubjectDetails(state: state, commentCount: comments, latestEvent: TimelineEvent(kind: kind, actor: actor, date: date, url: nil, target: target))
    }

    static func pullRequest(
        _ number: Int,
        _ title: String,
        in repository: String,
        by author: Actor,
        updated: Date,
        size: (additions: Int, deletions: Int),
        isDraft: Bool = false,
        checks: ChecksSummary?,
        decision: PullRequestSummary.ReviewDecision? = .reviewRequired,
        reviews: [PullRequestSummary.Review] = [],
        requestedReviewers: [PullRequestSummary.RequestedReviewer] = [.user(bob)],
        mergeable: String = "MERGEABLE",
        mergeState: String = "BLOCKED",
        unresolvedThreads: Int = 0,
        comments: [TimelineEvent] = [],
        requestedAt: Date? = nil,
        viaTeam team: String? = nil
    ) -> PullRequestSummary {
        let requests = requestedAt.map { [PullRequestSummary.ReviewRequestEvent(date: $0, reviewer: team ?? viewer.login, isTeam: team != nil)] }
        return PullRequestSummary(
            id: id(repository, number),
            number: number,
            title: title,
            url: URL(string: "https://github.com/\(repository)/pull/\(number)")!,
            repository: repository,
            isDraft: isDraft,
            createdAt: updated.addingTimeInterval(-86_400),
            updatedAt: updated,
            additions: size.additions,
            deletions: size.deletions,
            author: author,
            baseRefName: "main",
            headRefName: "\(author.login)/\(title.lowercased().split(separator: " ").prefix(3).joined(separator: "-"))",
            isCrossRepository: false,
            reviewDecision: decision,
            reviews: reviews,
            requestedReviewers: requestedReviewers,
            checks: checks,
            mergeable: mergeable,
            mergeStateStatus: mergeState,
            unresolvedThreads: unresolvedThreads,
            comments: comments,
            reviewRequestEvents: requests ?? []
        )
    }

    static func reviewed(
        _ number: Int,
        _ title: String,
        in repository: String,
        by author: Actor,
        state: SubjectState,
        involvement: ReviewedPullRequest.Involvement,
        since: Date,
        events: [TimelineEvent] = [],
        hasNewCommits: Bool = false,
        threads: ReviewedPullRequest.ThreadCount? = nil
    ) -> ReviewedPullRequest {
        let finish = events.last { $0.kind == .merged || $0.kind == .closed }
        return ReviewedPullRequest(
            id: id(repository, number),
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

    // MARK: Avatars

    /// Drawn here instead of loaded from GitHub, whose avatars are photos of real people. The list
    /// clips them to a circle, or a rounded square for organizations.
    static let avatarColors: [String: Int] = [
        "octo-dev": 0x6E7781,
        "alice": 0x7C5CFF,
        "bob": 0x1F9E89,
        "carol": 0xE07A3F,
        "dave": 0x3B82F6,
        "erin": 0xD9488F,
        "frank": 0x4F9D3A,
        "grace": 0xC08A1E,
        "dependabot": 0x0969DA,
        "acme": 0x4F46E5,
        "northwind": 0x0E8A7E,
    ]

    static var avatarDirectory: URL {
        DemoSnapshot.storageDirectory.appending(path: "avatars", directoryHint: .isDirectory)
    }

    static func avatarURL(_ login: String) -> URL {
        avatarDirectory.appending(path: "\(login).png")
    }

    static func writeAvatars() {
        try? FileManager.default.createDirectory(at: avatarDirectory, withIntermediateDirectories: true)
        let side = 64.0
        for (login, hex) in avatarColors {
            let color = NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1
            )
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side), bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            )?.retagging(with: .sRGB) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            let bounds = NSRect(x: 0, y: 0, width: side, height: side)
            NSGradient(starting: color.blended(withFraction: 0.3, of: .white) ?? color, ending: color)?.draw(in: bounds, angle: -90)
            if login == "dependabot", let robot = NSImage.icon(.bot, size: 40) {
                let white = NSImage(size: robot.size, flipped: false) { rect in
                    robot.draw(in: rect)
                    NSColor.white.set()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                white.draw(in: bounds.insetBy(dx: 12, dy: 12))
            } else {
                let base = NSFont.systemFont(ofSize: 36, weight: .semibold)
                let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 36) } ?? base
                let letter = NSAttributedString(string: login.prefix(1).uppercased(), attributes: [.font: font, .foregroundColor: NSColor.white])
                let width = letter.size().width
                // Centers the capital, not the line with its descender.
                letter.draw(at: NSPoint(x: (side - width) / 2, y: (side - font.capHeight) / 2 + font.descender))
            }
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?.write(to: avatarURL(login))
        }
    }
}
#endif
