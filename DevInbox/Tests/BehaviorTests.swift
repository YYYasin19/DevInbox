import Foundation
import Testing
@testable import DevInbox

struct SnoozeTests {
    private let snoozedAt = Date(timeIntervalSince1970: 1_000_000)

    @Test func notificationWakesOnTimeOrNewActivity() {
        let entry = SnoozeEntry(until: snoozedAt.addingTimeInterval(3600), updatedAtWhenSnoozed: snoozedAt, title: "", subtitle: "")
        #expect(entry.isActive(now: snoozedAt.addingTimeInterval(60), currentUpdatedAt: snoozedAt))
        #expect(!entry.isActive(now: snoozedAt.addingTimeInterval(3600), currentUpdatedAt: snoozedAt))
        #expect(!entry.isActive(now: snoozedAt.addingTimeInterval(60), currentUpdatedAt: snoozedAt.addingTimeInterval(30)))
    }

    @Test func reviewOnlyWakesOnTime() {
        let entry = SnoozeEntry(until: snoozedAt.addingTimeInterval(3600), title: "", subtitle: "")
        #expect(entry.isActive(now: snoozedAt.addingTimeInterval(60), currentUpdatedAt: snoozedAt.addingTimeInterval(30)))
        #expect(!entry.isActive(now: snoozedAt.addingTimeInterval(3601), currentUpdatedAt: nil))
    }

    @Test func presetsLandOnTheNextMorning() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        // Saturday, 2026-10-10 23:30 in Berlin.
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 23, minute: 30)))
        let tomorrow = calendar.dateComponents([.day, .hour, .minute], from: SnoozeOption.tomorrowMorning.date(from: now, calendar: calendar))
        #expect(tomorrow == DateComponents(day: 11, hour: 9, minute: 0))
        let monday = calendar.dateComponents([.weekday, .day, .hour], from: SnoozeOption.nextMonday.date(from: now, calendar: calendar))
        #expect(monday == DateComponents(day: 12, hour: 9, weekday: 2))

        // Monday 7:00: "next Monday" is a week later, not in two hours.
        let mondayMorning = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 7)))
        let following = calendar.dateComponents([.weekday, .day, .hour], from: SnoozeOption.nextMonday.date(from: mondayMorning, calendar: calendar))
        #expect(following == DateComponents(day: 19, hour: 9, weekday: 2))
    }
}

struct BannerPlannerTests {
    private func thread(_ id: String, reason: String, updatedAt: TimeInterval, unread: Bool = true) throws -> NotificationThread {
        let json = """
        {"id":"\(id)","unread":\(unread),"reason":"\(reason)","updated_at":"\(Date(timeIntervalSince1970: updatedAt).formatted(.iso8601))",
         "last_read_at":null,"subject":{"title":"T","url":null,"latest_comment_url":null,"type":"PullRequest"},
         "repository":{"full_name":"acme/api","html_url":"https://github.com/acme/api","owner":{"login":"acme","avatar_url":null}}}
        """
        return try GitHubClient.restDecoder.decode(NotificationThread.self, from: Data(json.utf8))
    }

    @Test func firstRunOnlyRecordsBaseline() throws {
        let threads = [try thread("1", reason: "mention", updatedAt: 100)]
        let plan = BannerPlanner.plan(threads: threads, baseline: nil, reasons: [.mention], isSnoozed: { _ in false })
        #expect(plan.announce.isEmpty)
        #expect(plan.baseline["1"] == SeenThread(unread: true, reason: .mention))
    }

    @Test func announcesNewAndNewlyUnreadImportantThreadsOnce() throws {
        let baseline = [
            "1": SeenThread(unread: true, reason: .mention),
            "2": SeenThread(unread: false, reason: .reviewRequested),
            "7": SeenThread(unread: true, reason: .mention),
            "8": SeenThread(unread: true, reason: .mention),
        ]
        let threads = [
            try thread("1", reason: "mention", updatedAt: 100),            // unchanged
            try thread("2", reason: "review_requested", updatedAt: 200),   // unread again
            try thread("3", reason: "mention", updatedAt: 150),            // new
            try thread("4", reason: "subscribed", updatedAt: 150),         // not important
            try thread("5", reason: "mention", updatedAt: 150, unread: false),
            try thread("6", reason: "mention", updatedAt: 150),            // snoozed
            try thread("7", reason: "mention", updatedAt: 300),            // only updated_at moved
            try thread("8", reason: "review_requested", updatedAt: 300),   // reason changed
        ]
        let plan = BannerPlanner.plan(threads: threads, baseline: baseline, reasons: [.mention, .reviewRequested], isSnoozed: { $0.id == "6" })
        #expect(plan.announce.map(\.id) == ["2", "3", "8"])

        let again = BannerPlanner.plan(threads: threads, baseline: plan.baseline, reasons: [.mention, .reviewRequested], isSnoozed: { _ in false })
        #expect(again.announce.isEmpty)
    }

    /// Closing a pull request makes its review request unread again; only an open one still asks for you.
    @Test func skipsReviewRequestsOfClosedPullRequests() throws {
        let baseline = [
            "1": SeenThread(unread: false, reason: .reviewRequested),
            "2": SeenThread(unread: false, reason: .reviewRequested),
            "3": SeenThread(unread: false, reason: .mention),
        ]
        let threads = [
            try thread("1", reason: "review_requested", updatedAt: 200),
            try thread("2", reason: "review_requested", updatedAt: 200),
            try thread("3", reason: "mention", updatedAt: 200),
        ]
        let details = [
            "1": SubjectDetails(state: .closed, commentCount: 0, latestEvent: nil),
            "2": SubjectDetails(state: .open, commentCount: 0, latestEvent: nil),
            "3": SubjectDetails(state: .merged, commentCount: 0, latestEvent: nil),
        ]
        let plan = BannerPlanner.plan(threads: threads, details: details, baseline: baseline, reasons: [.mention, .reviewRequested], isSnoozed: { _ in false })
        #expect(plan.announce.map(\.id) == ["2", "3"])
        #expect(plan.baseline["1"] == SeenThread(unread: true, reason: .reviewRequested))
    }
}

struct DismissedReviewTests {
    private let dismissedAt = Date(timeIntervalSince1970: 1_000_000)

    @Test func leavesTheListAfterThirtyDaysButStaysDismissed() throws {
        let file = JSONFileStore<[String: DismissedReview]>(name: "dismissed.json", directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let store = DismissedReviewStore(file: file)
        store.dismiss(DismissedReview(title: "T", repository: "acme/api", number: 7, dismissedAt: dismissedAt))
        #expect(store.listedEntries(now: dismissedAt.addingTimeInterval(29 * 86_400)).count == 1)
        #expect(store.listedEntries(now: dismissedAt.addingTimeInterval(31 * 86_400)).isEmpty)
        #expect(store.entries["acme/api#7"] != nil)

        store.unlist(key: "acme/api#7")
        #expect(store.listedEntries(now: dismissedAt).isEmpty)
        #expect(store.entries["acme/api#7"] != nil)
    }

    @Test func entriesSavedBeforeListingDecodeAsListed() throws {
        let json = #"{"title":"T","repository":"acme/api","number":7,"dismissedAt":"2026-10-10T12:00:00Z"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(DismissedReview.self, from: Data(json.utf8)).isListed)
    }
}

struct InboxFilterTests {
    private func details(state: SubjectState = .open, actor: Actor?) -> SubjectDetails {
        SubjectDetails(
            state: state,
            commentCount: 0,
            latestEvent: actor.map { TimelineEvent(kind: .commented, actor: $0, date: .now, url: nil) }
        )
    }

    @Test func botsAreAppsOrMachineUsers() {
        #expect(Actor(login: "github-actions", avatarUrl: nil, typename: "Bot").isBot)
        #expect(Actor(login: "dependabot[bot]", avatarUrl: nil).isBot)
        #expect(Actor(login: "regro-cf-autotick-bot", avatarUrl: nil, typename: "User").isBot)
        #expect(Actor(login: "release_bot", avatarUrl: nil).isBot)
        #expect(Actor(login: "conda-forge-admin", avatarUrl: nil, typename: "User", name: "automatic conda-forge administrator").isBot)
        #expect(!Actor(login: "abbott", avatarUrl: nil, typename: "User").isBot)
        #expect(!Actor(login: "alice", avatarUrl: nil, typename: "User", name: "Alice Example").isBot)
        #expect(!Actor(login: "dana", avatarUrl: nil, typename: "User", name: "Dana Abbotsford").isBot)
    }

    @Test func correctionsWinOverTheDetection() {
        let admin = details(actor: Actor(login: "Some-Admin", avatarUrl: nil, typename: "User"))
        #expect(InboxFilter.isFromPerson(admin))
        #expect(!InboxFilter.isFromPerson(admin, overrides: ["some-admin": true]))
        let app = details(actor: Actor(login: "helper", avatarUrl: nil, typename: "Bot"))
        #expect(InboxFilter.isFromPerson(app, overrides: ["helper": false]))
    }

    @Test func threadsWithoutAPersonCountAsBots() {
        #expect(InboxFilter.matches(details(actor: Actor(login: "alice", avatarUrl: nil, typename: "User")), actor: .people, finishedOnly: false))
        #expect(InboxFilter.matches(details(actor: Actor(login: "github-actions", avatarUrl: nil, typename: "Bot")), actor: .bots, finishedOnly: false))
        #expect(InboxFilter.matches(details(actor: nil), actor: .bots, finishedOnly: false))
        #expect(InboxFilter.matches(nil, actor: .bots, finishedOnly: false))
        #expect(!InboxFilter.matches(nil, actor: .people, finishedOnly: false))
    }

    @Test func closedMeansMergedOrClosed() {
        let person = Actor(login: "alice", avatarUrl: nil, typename: "User")
        for state in [SubjectState.merged, .closed, .closedNotPlanned] {
            #expect(InboxFilter.matches(details(state: state, actor: person), actor: .all, finishedOnly: true))
        }
        for state in [SubjectState.open, .draft] {
            #expect(!InboxFilter.matches(details(state: state, actor: person), actor: .all, finishedOnly: true))
        }
        #expect(!InboxFilter.matches(nil, actor: .all, finishedOnly: true))
    }
}

struct StableListTests {
    private struct Item: Identifiable, Equatable {
        let id: String
        var version = 0
    }

    private func items(_ ids: String...) -> [Item] {
        ids.map { Item(id: $0) }
    }

    @Test func holdingKeepsTheOrderAndHoldsNewItemsBack() {
        var list = StableList<Item>()
        list.update(items("a", "b", "c"), holding: true) // nothing shown yet: everything shows
        #expect(list.shown.map(\.id) == ["a", "b", "c"])

        // "d" is new, "c" moved to the top with fresh values, "b" is gone.
        list.update([Item(id: "d"), Item(id: "c", version: 1), Item(id: "a")], holding: true)
        #expect(list.shown == [Item(id: "a"), Item(id: "c", version: 1)])
        #expect(list.held.map(\.id) == ["d"])

        list.showAll()
        #expect(list.shown.map(\.id) == ["d", "c", "a"])
        #expect(list.held.isEmpty)
    }

    @Test func withoutHoldingEverythingShowsAtOnce() {
        var list = StableList<Item>()
        list.update(items("a", "b"), holding: false)
        list.update(items("c", "a"), holding: false)
        #expect(list.shown.map(\.id) == ["c", "a"])
        #expect(list.held.isEmpty)
    }

    @Test func reinsertPutsItemsBackWhereTheyWere() {
        var list = StableList<Item>()
        list.update(items("a", "b"), holding: true)
        list.update(items("n", "a", "b", "c"), holding: true) // "n" and "c" are held
        let removed = Set(["a", "c"])
        let positions = list.positions(of: removed)
        let items = list.all.filter { removed.contains($0.id) }
        list.modify { $0.removeAll { removed.contains($0.id) } }
        list.reinsert(items, at: positions)
        #expect(list.shown.map(\.id) == ["a", "b"])
        #expect(list.all.map(\.id) == ["n", "a", "b", "c"])
    }

    @Test func localChangesReachHeldItemsToo() {
        var list = StableList<Item>()
        list.update(items("a"), holding: true)
        list.update(items("b", "a"), holding: true)
        list.modify { $0.removeAll { $0.id == "b" } }
        list.showAll()
        #expect(list.shown.map(\.id) == ["a"])
    }
}
