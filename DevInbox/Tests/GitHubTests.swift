import Foundation
import Testing
@testable import DevInbox

struct URLMappingTests {
    private func thread(type: String, url: String?, latestComment: String? = nil) throws -> NotificationThread {
        let json: [String: Any] = [
            "id": "1",
            "unread": true,
            "reason": "mention",
            "updated_at": "2026-10-09T23:25:35Z",
            "last_read_at": NSNull(),
            "subject": [
                "title": "Title",
                "url": url as Any? ?? NSNull(),
                "latest_comment_url": latestComment as Any? ?? NSNull(),
                "type": type,
            ],
            "repository": [
                "full_name": "acme/api",
                "html_url": "https://github.com/acme/api",
                "owner": ["login": "acme", "avatar_url": "https://avatars.githubusercontent.com/u/9"],
            ],
        ]
        return try GitHubClient.restDecoder.decode(NotificationThread.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test func pullRequestJumpsToLatestIssueComment() throws {
        let thread = try thread(
            type: "PullRequest",
            url: "https://api.github.com/repos/acme/api/pulls/12",
            latestComment: "https://api.github.com/repos/acme/api/issues/comments/555"
        )
        #expect(thread.number == 12)
        #expect(URLMapping.target(for: thread) == .browser(URL(string: "https://github.com/acme/api/pull/12#issuecomment-555")!))
    }

    @Test func reviewCommentAnchorsToDiscussion() throws {
        let thread = try thread(
            type: "PullRequest",
            url: "https://api.github.com/repos/acme/api/pulls/12",
            latestComment: "https://api.github.com/repos/acme/api/pulls/comments/77"
        )
        #expect(URLMapping.target(for: thread) == .browser(URL(string: "https://github.com/acme/api/pull/12#discussion_r77")!))
    }

    @Test func noAnchorWhenLatestCommentIsTheSubject() throws {
        let url = "https://api.github.com/repos/acme/api/issues/3"
        let thread = try thread(type: "Issue", url: url, latestComment: url)
        #expect(URLMapping.target(for: thread) == .browser(URL(string: "https://github.com/acme/api/issues/3")!))
    }

    @Test func releasesNeedResolving() throws {
        let thread = try thread(type: "Release", url: "https://api.github.com/repos/acme/api/releases/42")
        #expect(URLMapping.target(for: thread) == .resolve(
            api: URL(string: "https://api.github.com/repos/acme/api/releases/42")!,
            fallback: URL(string: "https://github.com/acme/api/releases")!
        ))
    }

    @Test func linkHeaderNextPage() {
        let header = #"<https://api.github.com/notifications?page=2>; rel="next", <https://api.github.com/notifications?page=5>; rel="last""#
        #expect(GitHubResponse.nextLink(in: header) == URL(string: "https://api.github.com/notifications?page=2"))
        #expect(GitHubResponse.nextLink(in: #"<https://api.github.com/x?page=1>; rel="prev""#) == nil)
    }
}

struct SubjectEnrichmentTests {
    private func decodeFixture() throws -> (data: [String: SubjectEnrichment.RepositoryNode?], errors: [GraphQLErrorItem]) {
        struct Envelope: Decodable {
            let data: [String: SubjectEnrichment.RepositoryNode?]
            let errors: [GraphQLErrorItem]
        }
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: "subject-enrichment", withExtension: "json"))
        let envelope = try GitHubClient.restDecoder.decode(Envelope.self, from: Data(contentsOf: url))
        return (envelope.data, envelope.errors)
    }

    private func details(_ alias: String, viewer: String = "me") throws -> SubjectDetails? {
        let (data, _) = try decodeFixture()
        guard let subject = data[alias]??.issueOrPullRequest else { return nil }
        return SubjectDetails(
            state: subject.state,
            commentCount: subject.commentCount,
            latestEvent: TimelineEvent.latestRelevant(in: subject.timeline.compactMap(\.event), viewer: viewer, merged: subject.state == .merged)
        )
    }

    @Test func mergedPullRequestShowsMergeNotTheTrailingClose() throws {
        let details = try #require(try details("s0"))
        #expect(details.state == .merged)
        #expect(details.commentCount == 5)
        #expect(details.latestEvent?.kind == .merged)
        #expect(details.latestEvent?.actor?.login == "bob")
    }

    @Test func ownActivityIsSkippedInFavorOfOthers() throws {
        // The viewer commented last (and has a pending review); the notification is about carol's review.
        let event = try #require(try details("s1")?.latestEvent)
        #expect(event.kind == .changesRequested)
        #expect(event.actor?.login == "carol")
        #expect(event.date == ISO8601DateFormatter().date(from: "2026-10-08T10:05:00Z"))
        #expect(event.url == URL(string: "https://github.com/acme/api/pull/12#pullrequestreview-99"))
    }

    @Test func ownActivityIsUsedWhenNothingElseHappened() throws {
        let event = try #require(try details("s1", viewer: "carol")?.latestEvent)
        #expect(event.actor?.login == "me")
        #expect(event.kind == .commented)
    }

    @Test func issueStateAndAssignmentFromTheViewersPerspective() throws {
        let details = try #require(try details("s2"))
        #expect(details.state == .closedNotPlanned)
        #expect(details.latestEvent?.verb(viewer: "me") == "assigned you")
        #expect(details.latestEvent?.verb(viewer: "someone") == "assigned @me")
    }

    @Test func inaccessibleSubjectsAndRestrictedOrganizations() throws {
        let (data, errors) = try decodeFixture()
        #expect(data["s3"] != nil && data["s3"]! == nil)
        #expect(SubjectEnrichment.restrictedOrganizations(in: errors) == ["secret-org"])
    }
}

private final class BundleToken {}

struct StackResolverTests {
    private func pr(_ number: Int, base: String, head: String, repository: String = "acme/api", fromFork: Bool = false) -> PullRequestSummary {
        PullRequestSummary(
            id: "PR_\(number)", number: number, title: "PR \(number)", url: URL(string: "https://github.com/\(repository)/pull/\(number)")!,
            repository: repository, isDraft: false, createdAt: .now, updatedAt: .now, additions: 0, deletions: 0, author: nil,
            baseRefName: base, headRefName: head, isCrossRepository: fromFork, reviewDecision: nil, reviews: [], requestedReviewers: [], checks: nil,
            mergeable: "UNKNOWN", mergeStateStatus: "UNKNOWN", unresolvedThreads: 0, comments: [], reviewRequestEvents: []
        )
    }

    @Test func branchChainGivesPositionAndLength() throws {
        let bottom = pr(10, base: "main", head: "auth")
        let middle = pr(11, base: "auth", head: "api")
        let top = pr(12, base: "api", head: "ui")
        let unrelated = pr(13, base: "main", head: "docs")
        let otherRepo = pr(14, base: "ui", head: "more", repository: "acme/web")
        let all = [top, unrelated, bottom, middle, otherRepo]

        let info = try #require(StackResolver.fromBranches(for: middle, among: all))
        #expect(info.entries.map(\.number) == [10, 11, 12])
        #expect(info.position == 2)
        #expect(info.isNative == false)
        #expect(StackResolver.fromBranches(for: top, among: all)?.position == 3)
        #expect(StackResolver.fromBranches(for: unrelated, among: all) == nil)
        #expect(StackResolver.fromBranches(for: otherRepo, among: all) == nil)
    }

    @Test func forkBranchNamedLikeTheBaseIsNoStack() {
        // `contributor:main` → `main` must not become the parent of every other PR targeting `main`.
        let fork = pr(20, base: "main", head: "main", fromFork: true)
        let feature = pr(21, base: "main", head: "feature")
        #expect(StackResolver.fromBranches(for: fork, among: [fork, feature]) == nil)
        #expect(StackResolver.fromBranches(for: feature, among: [fork, feature]) == nil)
    }

    @Test func cyclicBranchesTerminate() {
        let a = pr(1, base: "b", head: "a")
        let b = pr(2, base: "a", head: "b")
        #expect(StackResolver.fromBranches(for: a, among: [a, b])?.count == 2)
    }

    @Test func nativeStackIncludesMergedLayers() throws {
        let json = #"""
        [{"id":1,"number":6671,"base":{"ref":"main"},"open":true,"pull_requests":[
          {"number":5343,"state":"closed","draft":false,"merged_at":"2026-09-14T15:04:06Z","head":{"ref":"a","sha":"1"}},
          {"number":6670,"state":"open","draft":true,"merged_at":null,"head":{"ref":"b","sha":"2"}}]}]
        """#
        let stacks = try GitHubClient.restDecoder.decode([StacksAPI.Stack].self, from: Data(json.utf8))
        let info = try #require(StackResolver.fromNative(stacks, number: 6670))
        #expect(info.position == 2)
        #expect(info.entries.map(\.state) == [.merged, .draft])
        #expect(StackResolver.fromNative(stacks, number: 1) == nil)
    }
}

struct NotificationsFetchTests {
    /// Answers like GitHub: with If-Modified-Since only the threads updated since then, otherwise all.
    private struct InboxTransport: HTTPTransport {
        let requests = Requests()

        final class Requests: @unchecked Sendable {
            var conditional: [Bool] = []
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let isConditional = request.value(forHTTPHeaderField: "If-Modified-Since") != nil
            requests.conditional.append(isConditional)
            let ids = isConditional ? ["3"] : ["1", "2", "3"]
            let body = try JSONSerialization.data(withJSONObject: ids.map(Self.thread))
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Last-Modified": "Sat, 11 Oct 2026 04:46:54 GMT"]
            )!
            return (body, response)
        }

        private static func thread(id: String) -> [String: Any] {
            [
                "id": id, "unread": true, "reason": "mention", "updated_at": "2026-10-11T04:46:54Z",
                "last_read_at": NSNull(),
                "subject": ["title": "T\(id)", "url": NSNull(), "latest_comment_url": NSNull(), "type": "Issue"],
                "repository": [
                    "full_name": "acme/api", "html_url": "https://github.com/acme/api",
                    "owner": ["login": "acme", "avatar_url": NSNull()],
                ],
            ]
        }
    }

    @Test func changedConditionalPollFetchesTheWholeInbox() async throws {
        let transport = InboxTransport()
        let api = NotificationsAPI(client: GitHubClient(token: "test", transport: transport))
        guard case .updated(let threads, _, _) = try await api.fetch(ifModifiedSince: "Sat, 11 Oct 2026 04:00:00 GMT") else {
            Issue.record("expected an update")
            return
        }
        #expect(threads.map(\.id) == ["1", "2", "3"])
        #expect(transport.requests.conditional == [true, false])
    }
}

struct DeferredReadTests {
    /// An inbox of three unread threads, newest first, that records every request. Like GitHub, it
    /// keeps listing threads after they're marked read and done.
    private struct InboxTransport: HTTPTransport {
        final class Recorder: @unchecked Sendable {
            var requests: [String] = []
            /// When thread 2 last changed; moving it is new activity.
            var secondUpdatedAt = "2026-10-11T09:00:00Z"
        }

        let recorder = Recorder()

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let method = request.httpMethod ?? "GET"
            recorder.requests.append("\(method) \(request.url!.path)")
            let body = method == "GET" ? try JSONSerialization.data(withJSONObject: [
                Self.thread(id: "1", updatedAt: "2026-10-11T10:00:00Z"),
                Self.thread(id: "2", updatedAt: recorder.secondUpdatedAt),
                Self.thread(id: "3", updatedAt: "2026-10-11T08:00:00Z"),
            ]) : Data()
            let response = HTTPURLResponse(url: request.url!, statusCode: method == "GET" ? 200 : 205, httpVersion: nil, headerFields: [:])!
            return (body, response)
        }

        private static func thread(id: String, updatedAt: String) -> [String: Any] {
            [
                "id": id, "unread": true, "reason": "mention", "updated_at": updatedAt, "last_read_at": NSNull(),
                "subject": ["title": "T\(id)", "url": NSNull(), "latest_comment_url": NSNull(), "type": "Issue"],
                "repository": [
                    "full_name": "acme/api", "html_url": "https://github.com/acme/api",
                    "owner": ["login": "acme", "avatar_url": NSNull()],
                ],
            ]
        }
    }

    private let readFile = JSONFileStore<[String: Date]>(
        name: "read.json", directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    )

    private func store(_ transport: InboxTransport) -> InboxStore {
        InboxStore(client: GitHubClient(token: "test", transport: transport), viewer: "me", readThreads: ReadThreads(file: readFile))
    }

    /// GitHub can't take "read" or "done" back, so an undone checkmark must never reach it.
    @Test func undoNeverReachesGitHub() async throws {
        let transport = InboxTransport()
        let store = store(transport)
        await store.refresh()
        #expect(store.threads.map(\.id) == ["1", "2", "3"])

        let pending = try #require(store.markReadLater(["2"]))
        #expect(store.threads.map(\.id) == ["1", "3"])
        await store.refresh(force: true) // a poll inside the undo window
        #expect(store.threads.map(\.id) == ["1", "3"])
        store.undo(pending)
        #expect(store.threads.map(\.id) == ["1", "2", "3"])
        #expect(transport.recorder.requests.allSatisfy { $0.hasPrefix("GET") })

        let again = try #require(store.markReadLater(["2"]))
        await store.commit(again)
        #expect(transport.recorder.requests.filter { !$0.hasPrefix("GET") } == [
            "PATCH /notifications/threads/2", "DELETE /notifications/threads/2",
        ])
    }

    /// GitHub keeps listing threads marked read and done, so they stay hidden, after a restart too,
    /// until they have new activity.
    @Test func readThreadsStayHiddenUntilNewActivity() async throws {
        let transport = InboxTransport()
        let first = store(transport)
        await first.refresh()
        await first.commit(try #require(first.markReadLater(["2"])))

        let afterRestart = store(transport)
        await afterRestart.refresh()
        #expect(afterRestart.threads.map(\.id) == ["1", "3"])

        transport.recorder.secondUpdatedAt = Date.now.addingTimeInterval(60).formatted(.iso8601)
        await afterRestart.refresh(force: true)
        #expect(afterRestart.threads.map(\.id) == ["2", "1", "3"])
    }
}

struct ReviewHistoryTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ minute: Int) -> Date {
        start.addingTimeInterval(Double(minute) * 60)
    }

    private func actor(_ login: String, typename: String = "User") -> [String: Any] {
        ["__typename": typename, "login": login, "avatarUrl": NSNull()]
    }

    private func node(state: String = "OPEN", head: String, reviews: [[String: Any]], threads: [[String: Any]] = [], timeline: [[String: Any]]) throws -> ReviewHistorySearch.Node {
        let json: [String: Any] = [
            "id": "PR_1", "number": 1, "title": "T", "url": "https://github.com/acme/api/pull/1", "state": state, "isDraft": false,
            "headRefOid": head, "mergedAt": state == "MERGED" ? at(50).formatted(.iso8601) : NSNull(),
            "repository": ["nameWithOwner": "acme/api"], "author": actor("alice"), "mergedBy": state == "MERGED" ? actor("bob") : NSNull(),
            "yourReviews": ["nodes": reviews], "reviewThreads": ["nodes": threads], "timelineItems": ["nodes": timeline],
        ]
        return try GitHubClient.restDecoder.decode(ReviewHistorySearch.Node.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func review(_ state: String, at minute: Int, commit: String) -> [String: Any] {
        ["state": state, "submittedAt": at(minute).formatted(.iso8601), "commit": ["oid": commit]]
    }

    private func event(_ typename: String, by author: [String: Any], at minute: Int, state: String? = nil) -> [String: Any] {
        var event: [String: Any] = ["__typename": typename, "author": author, "actor": author, "createdAt": at(minute).formatted(.iso8601)]
        if let state {
            event["state"] = state
            event["submittedAt"] = at(minute).formatted(.iso8601)
        }
        return event
    }

    private func commit(by login: String, at minute: Int) -> [String: Any] {
        ["__typename": "PullRequestCommit", "commit": ["committedDate": at(minute).formatted(.iso8601), "authors": ["nodes": [["user": actor(login)]]]]]
    }

    private func thread(startedBy: String, lastBy: String, at minute: Int, resolved: Bool) -> [String: Any] {
        [
            "isResolved": resolved,
            "firstComment": ["nodes": [["author": ["login": startedBy]]]],
            "lastComment": ["nodes": [["author": actor(lastBy), "createdAt": at(minute).formatted(.iso8601)]]],
        ]
    }

    /// Since your last review: what others did, without bots, your own activity or the close that comes
    /// with a merge. An unchanged head means no new commits, whatever the commit dates say.
    @Test func reviewedPullRequestShowsWhatOthersDidSince() throws {
        let pullRequest = try #require(try node(
            state: "MERGED",
            head: "b",
            reviews: [review("APPROVED", at: 0, commit: "a"), review("COMMENTED", at: 10, commit: "b")],
            threads: [
                thread(startedBy: "me", lastBy: "alice", at: 35, resolved: true),
                thread(startedBy: "me", lastBy: "me", at: 36, resolved: false),
                thread(startedBy: "alice", lastBy: "bob", at: 37, resolved: false),
            ],
            timeline: [
                event("IssueComment", by: actor("alice"), at: 5),
                commit(by: "alice", at: 20),
                event("IssueComment", by: actor("me"), at: 30),
                event("IssueComment", by: actor("ci", typename: "Bot"), at: 31),
                event("IssueComment", by: actor("alice"), at: 32),
                event("PullRequestReview", by: actor("bob"), at: 40, state: "APPROVED"),
                event("MergedEvent", by: actor("bob"), at: 50),
                event("ClosedEvent", by: actor("bob"), at: 50),
            ]
        ).pullRequest(viewer: "Me", left: nil))

        #expect(pullRequest.involvement == .approved)
        #expect(pullRequest.since == at(10))
        #expect(!pullRequest.hasNewCommits)
        #expect(pullRequest.events.map(\.kind) == [.commented, .replied, .approved, .merged])
        #expect(pullRequest.yourThreads == .init(resolved: 1, total: 2))
        #expect(pullRequest.state == .merged && pullRequest.finishedBy?.login == "bob")
    }

    /// A review from before the request doesn't answer it: the history starts when the request left.
    @Test func requestThatLeftWithoutReview() throws {
        let pullRequest = try node(
            head: "c",
            reviews: [review("COMMENTED", at: 0, commit: "a")],
            timeline: [commit(by: "alice", at: 15), commit(by: "alice", at: 25)]
        )
        let ended = PastReviewRequest(id: "PR_1", requestedAt: at(5), leftAt: at(20))

        let afterEnd = try #require(pullRequest.pullRequest(viewer: "me", left: ended))
        #expect(afterEnd.involvement == .requestEnded)
        #expect(afterEnd.since == at(20))
        #expect(afterEnd.hasNewCommits && afterEnd.events.map(\.kind) == [.committed])

        var dismissed = ended
        dismissed.wasDismissed = true
        #expect(pullRequest.pullRequest(viewer: "me", left: dismissed)?.involvement == .requestDismissed)

        // Without that request, the old review counts, and the moved head says there are new commits.
        let reviewed = try #require(pullRequest.pullRequest(viewer: "me", left: nil))
        #expect(reviewed.involvement == .commented && reviewed.since == at(0) && reviewed.hasNewCommits)
    }

    private func requested(id: String) -> PullRequestSummary {
        PullRequestSummary(
            id: id, number: 1, title: "T", url: URL(string: "https://github.com/acme/api/pull/1")!, repository: "acme/api",
            isDraft: false, createdAt: .now, updatedAt: .now, additions: 0, deletions: 0, author: nil, baseRefName: "main",
            headRefName: id, isCrossRepository: false, reviewDecision: nil, reviews: [], requestedReviewers: [], checks: nil,
            mergeable: "UNKNOWN", mergeStateStatus: "UNKNOWN", unresolvedThreads: 0, comments: [], reviewRequestEvents: []
        )
    }

    @Test func requestsLeaveTheListWhenTheyEndOrAreDismissed() {
        let file = JSONFileStore<[String: PastReviewRequest]>(
            name: "past-review-requests.json", directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        )
        let store = PastReviewRequestStore(file: file)
        let a = requested(id: "PR_a"), b = requested(id: "PR_b")

        store.update(requested: [a, b], viewer: "me", dismissedAt: { _ in nil }, now: at(0))
        #expect(store.left.isEmpty)

        store.update(requested: [b], viewer: "me", dismissedAt: { $0.id == "PR_b" ? at(5) : nil }, now: at(10))
        #expect(store.left.map(\.id) == ["PR_a", "PR_b"])
        #expect(store.left.map(\.wasDismissed) == [false, true])
        #expect(PastReviewRequestStore(file: file).left == store.left)

        // Requested again, or brought back: waiting again.
        store.update(requested: [a, b], viewer: "me", dismissedAt: { _ in nil }, now: at(20))
        #expect(store.left.isEmpty)

        store.update(requested: [], viewer: "me", dismissedAt: { _ in nil }, now: at(30))
        store.update(requested: [], viewer: "me", dismissedAt: { _ in nil }, now: at(30).addingTimeInterval(ReviewHistorySearch.window))
        #expect(store.entries.isEmpty)
    }
}
