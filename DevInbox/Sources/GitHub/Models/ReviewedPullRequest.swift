import Foundation

/// A pull request you reviewed, or were asked to review, and what happened to it since.
nonisolated struct ReviewedPullRequest: Identifiable, Hashable, Sendable {
    /// Your part in it, as of `since`.
    enum Involvement: Hashable, Sendable {
        case approved, changesRequested, commented
        /// Your review was dismissed, usually because new commits made it stale.
        case reviewDismissed
        /// You dismissed the review request in DevInbox.
        case requestDismissed
        /// The request went away without a review from you: withdrawn, or a teammate reviewed it.
        case requestEnded
    }

    struct ThreadCount: Hashable, Sendable {
        let resolved: Int
        let total: Int
    }

    let id: String
    let number: Int
    let title: String
    let url: URL
    let repository: String
    let author: Actor?
    let state: SubjectState
    /// Who merged or closed it, and when.
    let finishedBy: Actor?
    let finishedAt: Date?
    let involvement: Involvement
    /// When you last reviewed, or when the request left your list. `events` happened after it.
    let since: Date
    /// What others did since, oldest first. Your own activity and bots' comments and reviews are left out.
    let events: [TimelineEvent]
    /// The branch changed since. Where you reviewed, that's the head commit against the one you reviewed,
    /// so it doesn't depend on commit dates.
    let hasNewCommits: Bool
    /// Review threads you started.
    let yourThreads: ThreadCount?

    var lastActivity: Date { events.last?.date ?? since }
}

/// Finds the pull requests you reviewed with activity in the last 30 days, plus the review requests
/// that left your list without a review (GitHub's search can't find those), and works out what happened
/// to each since.
nonisolated enum ReviewHistorySearch {
    static let window: TimeInterval = 30 * 86_400
    static let pageSize = 25
    /// Up to 50 reviewed pull requests.
    static let maxPages = 2

    static func searchQuery(now: Date) -> String {
        let start = now.addingTimeInterval(-window).formatted(.iso8601.year().month().day())
        return "is:pr reviewed-by:@me -author:@me archived:false updated:>=\(start) sort:updated-desc"
    }

    static func fetch(viewer: String, left: [PastReviewRequest], now: Date = .now, client: GitHubClient) async throws -> [ReviewedPullRequest] {
        let leftByID = Dictionary(left.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var nodes: [Node] = []
        var cursor: String?
        for page in 0..<maxPages {
            var variables = ["q": searchQuery(now: now), "viewer": viewer]
            variables["after"] = cursor
            let leftIDs = page == 0 ? leftByID.keys.sorted() : []
            let (data, _) = try await client.graphQL(query(leftIDs: leftIDs), variables: variables, as: Response.self)
            nodes += data.search.nodes.compactMap(\.node) + (data.left?.compactMap { $0?.node } ?? [])
            guard data.search.pageInfo.hasNextPage, let next = data.search.pageInfo.endCursor else { break }
            cursor = next
        }
        var seen = Set<String>()
        return nodes
            .filter { seen.insert($0.id).inserted }
            .compactMap { $0.pullRequest(viewer: viewer, left: leftByID[$0.id]) }
    }

    static func query(leftIDs: [String]) -> String {
        let left = leftIDs.isEmpty ? "" : "left: nodes(ids: [\(leftIDs.map(\.graphQLQuoted).joined(separator: ", "))]) { ...HistoryFields }"
        return """
        query($q: String!, $viewer: String!, $after: String) {
          search(query: $q, type: ISSUE, first: \(pageSize), after: $after) {
            pageInfo { hasNextPage endCursor }
            nodes { ...HistoryFields }
          }
          \(left)
        }
        \(SubjectEnrichment.actorFragment)
        \(SubjectEnrichment.pullRequestTimelineFragment)
        fragment HistoryFields on PullRequest {
          id number title url state isDraft headRefOid mergedAt
          repository { nameWithOwner }
          author { login avatarUrl }
          mergedBy { ...ActorFields }
          yourReviews: reviews(last: 20, author: $viewer, states: [APPROVED, CHANGES_REQUESTED, COMMENTED, DISMISSED]) {
            nodes { state submittedAt commit { oid } }
          }
          reviewThreads(first: 50) {
            nodes {
              isResolved
              firstComment: comments(first: 1) { nodes { author { login } } }
              lastComment: comments(last: 1) { nodes { author { ...ActorFields } createdAt url } }
            }
          }
          timelineItems(last: 40, itemTypes: [ISSUE_COMMENT, PULL_REQUEST_REVIEW, PULL_REQUEST_COMMIT, MERGED_EVENT, CLOSED_EVENT, REOPENED_EVENT, READY_FOR_REVIEW_EVENT, HEAD_REF_FORCE_PUSHED_EVENT]) {
            nodes { ...PullRequestTimelineFields }
          }
        }
        """
    }

    // MARK: - Decoding

    struct Response: Decodable {
        let search: Search
        let left: [OptionalNode?]?
    }

    struct Search: Decodable {
        let pageInfo: PullRequestSearch.PageInfo
        let nodes: [OptionalNode]

        private enum CodingKeys: String, CodingKey { case pageInfo, nodes }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            pageInfo = try container.decode(PullRequestSearch.PageInfo.self, forKey: .pageInfo)
            // GraphQL returns null entries for nodes the token cannot see.
            nodes = try container.decodeIfPresent([OptionalNode?].self, forKey: .nodes)?.compactMap { $0 } ?? []
        }
    }

    /// Search results can include other types, which decode as empty objects.
    struct OptionalNode: Decodable {
        let node: Node?

        private enum CodingKeys: String, CodingKey { case id }

        init(from decoder: Decoder) throws {
            node = try decoder.container(keyedBy: CodingKeys.self).contains(.id) ? Node(from: decoder) : nil
        }
    }

    struct Node: Decodable {
        let id: String
        let number: Int
        let title: String
        let url: URL
        let state: String
        let isDraft: Bool
        let headRefOid: String
        let mergedAt: Date?
        let repository: Repository
        let author: Actor?
        let mergedBy: Actor?
        let yourReviews: Nodes<Review>
        let reviewThreads: Nodes<Thread>
        let timelineItems: Nodes<SubjectEnrichment.TimelineNode>

        struct Repository: Decodable { let nameWithOwner: String }

        struct Review: Decodable {
            let state: String
            let submittedAt: Date?
            let commit: Commit?
        }

        struct Commit: Decodable { let oid: String }

        struct Thread: Decodable {
            let isResolved: Bool
            let firstComment: Nodes<FirstComment>
            let lastComment: Nodes<LastComment>
        }

        struct FirstComment: Decodable {
            struct Author: Decodable { let login: String }
            let author: Author?
        }

        struct LastComment: Decodable {
            let author: Actor?
            let createdAt: Date
            let url: URL?
        }

        /// Nil when you neither reviewed it nor saw its request leave your list.
        func pullRequest(viewer: String, left: PastReviewRequest?) -> ReviewedPullRequest? {
            func isViewer(_ login: String?) -> Bool {
                login?.caseInsensitiveCompare(viewer) == .orderedSame
            }

            let reviews = yourReviews.nodes
                .compactMap { review in review.submittedAt.map { (review: review, date: $0) } }
                .sorted { $0.date < $1.date }
            let involvement: ReviewedPullRequest.Involvement
            let since: Date
            let reviewedCommit: String?
            // A review from before the request that left doesn't answer it.
            if let latest = reviews.last, latest.date >= left?.requestedAt ?? .distantPast {
                involvement = switch reviews.last(where: { $0.review.state != "COMMENTED" })?.review.state {
                case "APPROVED": .approved
                case "CHANGES_REQUESTED": .changesRequested
                case "DISMISSED": .reviewDismissed
                default: .commented
                }
                since = latest.date
                reviewedCommit = latest.review.commit?.oid
            } else if let left, let leftAt = left.leftAt {
                involvement = left.wasDismissed ? .requestDismissed : .requestEnded
                since = leftAt
                reviewedCommit = nil
            } else {
                return nil
            }

            let merged = state == "MERGED"
            let timeline = timelineItems.nodes.compactMap(\.event)
            var events = timeline.filter { event in
                guard event.date > since, !isViewer(event.actor?.login) else { return false }
                switch event.kind {
                case .commented, .approved, .changesRequested, .reviewed: return !(event.actor?.isBot ?? false)
                // GitHub closes merged pull requests too; the merge says it all.
                case .closed: return !merged
                default: return true
                }
            }
            let yourThreads = reviewThreads.nodes.filter { isViewer($0.firstComment.nodes.first?.author?.login) }
            for thread in yourThreads {
                guard let reply = thread.lastComment.nodes.first, reply.createdAt > since,
                      !isViewer(reply.author?.login), !(reply.author?.isBot ?? false) else { continue }
                events.append(TimelineEvent(kind: .replied, actor: reply.author, date: reply.createdAt, url: reply.url))
            }
            let isPush: (TimelineEvent) -> Bool = { $0.kind == .committed || $0.kind == .forcePushed }
            // Commit dates are the author's, not when they were pushed: the head commit decides.
            let headMoved = reviewedCommit.map { $0 != headRefOid }
            if headMoved == false {
                events.removeAll(where: isPush)
            }
            events.sort { $0.date < $1.date }

            let subjectState: SubjectState = switch state {
            case "MERGED": .merged
            case "CLOSED": .closed
            default: isDraft ? .draft : .open
            }
            let finished: (actor: Actor?, date: Date?) = switch state {
            case "MERGED": (mergedBy, mergedAt)
            case "CLOSED": timeline.last { $0.kind == .closed }.map { ($0.actor, $0.date) } ?? (nil, nil)
            default: (nil, nil)
            }
            return ReviewedPullRequest(
                id: id,
                number: number,
                title: title,
                url: url,
                repository: repository.nameWithOwner,
                author: author,
                state: subjectState,
                finishedBy: finished.actor,
                finishedAt: finished.date,
                involvement: involvement,
                since: since,
                events: events,
                hasNewCommits: headMoved ?? events.contains(where: isPush),
                yourThreads: yourThreads.isEmpty
                    ? nil
                    : ReviewedPullRequest.ThreadCount(resolved: yourThreads.count(where: \.isResolved), total: yourThreads.count)
            )
        }
    }
}
