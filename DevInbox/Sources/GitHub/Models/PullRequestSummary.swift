import Foundation

nonisolated struct PullRequestSummary: Identifiable, Hashable, Sendable {
    let id: String
    let number: Int
    let title: String
    let url: URL
    let repository: String
    let isDraft: Bool
    let createdAt: Date
    let updatedAt: Date
    let additions: Int
    let deletions: Int
    let author: Actor?
    let baseRefName: String
    let headRefName: String
    /// The head branch lives in a fork, so `headRefName` doesn't name a branch of `repository`.
    let isCrossRepository: Bool
    let reviewDecision: ReviewDecision?
    let reviews: [Review]
    let requestedReviewers: [RequestedReviewer]
    let checks: ChecksSummary?
    let mergeable: String
    let mergeStateStatus: String
    let unresolvedThreads: Int
    /// The latest 50 conversation comments, oldest first. Review thread comments aren't among them.
    let comments: [TimelineEvent]
    /// Review requests from the timeline (latest last), used for "waiting since".
    let reviewRequestEvents: [ReviewRequestEvent]

    var subjectKey: String { "\(repository)#\(number)" }

    enum ReviewDecision: String, Hashable, Sendable {
        case approved = "APPROVED"
        case changesRequested = "CHANGES_REQUESTED"
        case reviewRequired = "REVIEW_REQUIRED"
    }

    struct Review: Hashable, Sendable {
        let author: Actor?
        let state: String
    }

    enum RequestedReviewer: Hashable, Sendable {
        case user(Actor)
        case team(name: String, slug: String)
    }

    struct ReviewRequestEvent: Hashable, Sendable {
        let date: Date
        let reviewer: String? // user login or team slug
        let isTeam: Bool
    }

    /// Comments by people other than the author: the ones that may need an answer. `overrides` are the
    /// Inbox's bot corrections; a deleted account still counts as a person.
    func commentsFromOthers(overrides: [String: Bool]) -> [TimelineEvent] {
        comments.filter { comment in
            guard let actor = comment.actor else { return true }
            return actor.login.caseInsensitiveCompare(author?.login ?? "") != .orderedSame && !actor.isBot(overrides: overrides)
        }
    }

    /// When the viewer's review was requested, directly or via a team.
    func reviewRequestedAt(viewer: String) -> Date? {
        let direct = reviewRequestEvents.last { !$0.isTeam && $0.reviewer?.caseInsensitiveCompare(viewer) == .orderedSame }
        return (direct ?? reviewRequestEvents.last { $0.isTeam })?.date
    }

    /// The team through which the viewer was asked, if not asked directly.
    func requestingTeam(viewer: String) -> String? {
        let askedDirectly = requestedReviewers.contains {
            if case .user(let actor) = $0 { actor.login.caseInsensitiveCompare(viewer) == .orderedSame } else { false }
        }
        guard !askedDirectly else { return nil }
        for reviewer in requestedReviewers {
            if case .team(let name, _) = reviewer { return name }
        }
        return nil
    }
}

nonisolated struct ChecksSummary: Hashable, Sendable {
    enum State: Hashable, Sendable {
        case success, failure, pending
    }

    let state: State
    let failing: [String]
    let pending: [String]
    let total: Int
}

nonisolated enum PullRequestSearch {
    static let reviewRequestsQuery = "is:pr is:open review-requested:@me archived:false sort:updated-desc"
    static let authoredQuery = "is:pr is:open author:@me archived:false sort:updated-desc"
    static let pageSize = 30
    /// Up to 120 pull requests per search.
    static let maxPages = 4

    static let query = """
    query($q: String!, $after: String) {
      search(query: $q, type: ISSUE, first: \(pageSize), after: $after) {
        issueCount
        pageInfo { hasNextPage endCursor }
        nodes {
          ... on PullRequest {
            id number title url isDraft createdAt updatedAt additions deletions
            baseRefName headRefName isCrossRepository
            repository { nameWithOwner }
            author { login avatarUrl }
            reviewDecision mergeable mergeStateStatus
            comments(last: 50) { nodes { author { __typename login avatarUrl ... on User { name } } createdAt url } }
            reviewThreads(first: 50) { nodes { isResolved } }
            latestOpinionatedReviews(first: 10) { nodes { state author { login avatarUrl } } }
            reviewRequests(first: 10) {
              nodes { requestedReviewer { __typename ... on User { login avatarUrl } ... on Team { name slug } } }
            }
            commits(last: 1) {
              nodes {
                commit {
                  statusCheckRollup {
                    state
                    contexts(first: 50) {
                      nodes {
                        __typename
                        ... on CheckRun { name status conclusion }
                        ... on StatusContext { context state }
                      }
                    }
                  }
                }
              }
            }
            timelineItems(last: 10, itemTypes: [REVIEW_REQUESTED_EVENT]) {
              nodes {
                ... on ReviewRequestedEvent {
                  createdAt
                  requestedReviewer { __typename ... on User { login } ... on Team { slug } }
                }
              }
            }
          }
        }
      }
    }
    """

    struct Result: Sendable {
        var pullRequests: [PullRequestSummary] = []
        var restrictedOrganizations: Set<String> = []
        /// How many GitHub found, which can be more than were fetched.
        var totalCount = 0
        /// False when more pages were left than `maxPages`.
        var isComplete = true
    }

    static func fetch(_ searchQuery: String, client: GitHubClient) async throws -> Result {
        var result = Result()
        var cursor: String?
        for _ in 0..<maxPages {
            var variables = ["q": searchQuery]
            variables["after"] = cursor
            let (data, errors) = try await client.graphQL(query, variables: variables, as: SearchData.self)
            result.pullRequests += data.search.nodes.compactMap(\.summary)
            result.restrictedOrganizations.formUnion(SubjectEnrichment.restrictedOrganizations(in: errors))
            result.totalCount = data.search.issueCount
            result.isComplete = !data.search.pageInfo.hasNextPage
            guard let next = data.search.pageInfo.endCursor, data.search.pageInfo.hasNextPage else { break }
            cursor = next
        }
        return result
    }

    // MARK: - Decoding

    struct SearchData: Decodable {
        let search: Search
    }

    struct Search: Decodable {
        let issueCount: Int
        let pageInfo: PageInfo
        let nodes: [Node]

        private enum CodingKeys: String, CodingKey { case issueCount, pageInfo, nodes }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            issueCount = try container.decode(Int.self, forKey: .issueCount)
            pageInfo = try container.decode(PageInfo.self, forKey: .pageInfo)
            // GraphQL returns null entries for nodes the token cannot see.
            nodes = try container.decodeIfPresent([Node?].self, forKey: .nodes)?.compactMap { $0 } ?? []
        }
    }

    struct PageInfo: Decodable {
        let hasNextPage: Bool
        let endCursor: String?
    }

    struct Node: Decodable {
        let summary: PullRequestSummary?

        private struct Repository: Decodable { let nameWithOwner: String }
        private struct Thread: Decodable { let isResolved: Bool }
        private struct ReviewNode: Decodable { let state: String; let author: Actor? }
        private struct RequestNode: Decodable { let requestedReviewer: Reviewer? }
        private struct Reviewer: Decodable {
            let __typename: String
            let login: String?
            let avatarUrl: URL?
            let name: String?
            let slug: String?
        }
        private struct CommitNode: Decodable { let commit: Commit }
        private struct Commit: Decodable { let statusCheckRollup: Rollup? }
        private struct Rollup: Decodable { let state: String; let contexts: Nodes<Context> }
        private struct Context: Decodable {
            let __typename: String
            let name: String?
            let status: String?
            let conclusion: String?
            let context: String?
            let state: String?
        }
        private struct TimelineNode: Decodable { let createdAt: Date?; let requestedReviewer: Reviewer? }
        private struct CommentNode: Decodable { let author: Actor?; let createdAt: Date; let url: URL? }

        private enum CodingKeys: String, CodingKey {
            case id, number, title, url, isDraft, createdAt, updatedAt, additions, deletions
            case baseRefName, headRefName, isCrossRepository, repository, author, reviewDecision, mergeable, mergeStateStatus
            case comments, reviewThreads, latestOpinionatedReviews, reviewRequests, commits, timelineItems
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Search results can include non-PR nodes, which decode as empty objects.
            guard let id = try container.decodeIfPresent(String.self, forKey: .id) else {
                summary = nil
                return
            }
            let rollup = try container.decode(Nodes<CommitNode>.self, forKey: .commits).nodes.first?.commit.statusCheckRollup
            let reviewers = try container.decode(Nodes<RequestNode>.self, forKey: .reviewRequests).nodes
                .compactMap(\.requestedReviewer)
                .compactMap { reviewer -> PullRequestSummary.RequestedReviewer? in
                    if let login = reviewer.login { return .user(Actor(login: login, avatarUrl: reviewer.avatarUrl)) }
                    if let slug = reviewer.slug { return .team(name: reviewer.name ?? slug, slug: slug) }
                    return nil
                }
            let requestEvents = try container.decode(Nodes<TimelineNode>.self, forKey: .timelineItems).nodes
                .compactMap { node -> PullRequestSummary.ReviewRequestEvent? in
                    guard let date = node.createdAt else { return nil }
                    let reviewer = node.requestedReviewer
                    return .init(date: date, reviewer: reviewer?.login ?? reviewer?.slug, isTeam: reviewer?.__typename == "Team")
                }

            summary = PullRequestSummary(
                id: id,
                number: try container.decode(Int.self, forKey: .number),
                title: try container.decode(String.self, forKey: .title),
                url: try container.decode(URL.self, forKey: .url),
                repository: try container.decode(Repository.self, forKey: .repository).nameWithOwner,
                isDraft: try container.decode(Bool.self, forKey: .isDraft),
                createdAt: try container.decode(Date.self, forKey: .createdAt),
                updatedAt: try container.decode(Date.self, forKey: .updatedAt),
                additions: try container.decode(Int.self, forKey: .additions),
                deletions: try container.decode(Int.self, forKey: .deletions),
                author: try container.decodeIfPresent(Actor.self, forKey: .author),
                baseRefName: try container.decode(String.self, forKey: .baseRefName),
                headRefName: try container.decode(String.self, forKey: .headRefName),
                isCrossRepository: try container.decode(Bool.self, forKey: .isCrossRepository),
                reviewDecision: try container.decodeIfPresent(String.self, forKey: .reviewDecision)
                    .flatMap(PullRequestSummary.ReviewDecision.init(rawValue:)),
                reviews: try container.decode(Nodes<ReviewNode>.self, forKey: .latestOpinionatedReviews).nodes
                    .map { .init(author: $0.author, state: $0.state) },
                requestedReviewers: reviewers,
                checks: rollup.map(Self.summarize),
                mergeable: try container.decode(String.self, forKey: .mergeable),
                mergeStateStatus: try container.decode(String.self, forKey: .mergeStateStatus),
                unresolvedThreads: try container.decode(Nodes<Thread>.self, forKey: .reviewThreads).nodes.filter { !$0.isResolved }.count,
                comments: try container.decode(Nodes<CommentNode>.self, forKey: .comments).nodes
                    .map { TimelineEvent(kind: .commented, actor: $0.author, date: $0.createdAt, url: $0.url) },
                reviewRequestEvents: requestEvents
            )
        }

        private static func summarize(_ rollup: Rollup) -> ChecksSummary {
            var failing: [String] = []
            var pending: [String] = []
            for context in rollup.contexts.nodes {
                if context.__typename == "CheckRun" {
                    let name = context.name ?? "Check"
                    if context.status != "COMPLETED" {
                        pending.append(name)
                    } else if ["FAILURE", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE"].contains(context.conclusion) {
                        failing.append(name)
                    }
                } else {
                    let name = context.context ?? "Status"
                    switch context.state {
                    case "FAILURE", "ERROR": failing.append(name)
                    case "PENDING", "EXPECTED": pending.append(name)
                    default: break
                    }
                }
            }
            let state: ChecksSummary.State = switch rollup.state {
            case "SUCCESS": .success
            case "FAILURE", "ERROR": .failure
            default: .pending
            }
            return ChecksSummary(state: state, failing: failing, pending: pending, total: rollup.contexts.nodes.count)
        }
    }
}
