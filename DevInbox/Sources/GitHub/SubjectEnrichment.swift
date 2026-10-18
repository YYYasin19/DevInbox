import Foundation

/// Fetches state and latest activity for issue / pull request notifications in one GraphQL request
/// per batch, using one alias per subject.
nonisolated enum SubjectEnrichment {
    struct Request: Hashable, Sendable {
        let key: String
        let owner: String
        let name: String
        let number: Int
    }

    struct Result: Sendable {
        var details: [String: SubjectDetails] = [:]
        var restrictedOrganizations: Set<String> = []
    }

    static let batchSize = 25

    static func fetch(_ requests: [Request], viewer: String, client: GitHubClient) async throws -> Result {
        guard !requests.isEmpty else { return Result() }
        let (data, errors) = try await client.graphQL(query(for: requests), as: [String: RepositoryNode?].self)
        var result = Result()
        result.restrictedOrganizations = restrictedOrganizations(in: errors)
        for (index, request) in requests.enumerated() {
            guard let node = data["s\(index)"] ?? nil, let subject = node.issueOrPullRequest else { continue }
            let events = subject.timeline.compactMap(\.event)
            result.details[request.key] = SubjectDetails(
                state: subject.state,
                commentCount: subject.commentCount,
                latestEvent: TimelineEvent.latestRelevant(in: events, viewer: viewer, merged: subject.state == .merged)
            )
        }
        return result
    }

    /// Organizations with OAuth App access restrictions answer with a FORBIDDEN error naming the org.
    static func restrictedOrganizations(in errors: [GraphQLErrorItem]) -> Set<String> {
        var organizations = Set<String>()
        for error in errors where error.message.contains("OAuth App access restrictions") {
            if let match = error.message.firstMatch(of: /the `([^`]+)` organization/) {
                organizations.insert(String(match.1))
            }
        }
        return organizations
    }

    static let actorFragment = "fragment ActorFields on Actor { __typename login avatarUrl ... on User { name } }"

    /// The pull request timeline items `TimelineNode` decodes. Needs `actorFragment`.
    static let pullRequestTimelineFragment = """
    fragment PullRequestTimelineFields on PullRequestTimelineItems {
      __typename
      ... on IssueComment { author { ...ActorFields } createdAt url }
      ... on PullRequestReview { author { ...ActorFields } state createdAt submittedAt url }
      ... on PullRequestCommit { commit { committedDate authors(first: 1) { nodes { user { login avatarUrl name } } } } }
      ... on MergedEvent { actor { ...ActorFields } createdAt }
      ... on ClosedEvent { actor { ...ActorFields } createdAt }
      ... on ReopenedEvent { actor { ...ActorFields } createdAt }
      ... on ReviewRequestedEvent { actor { ...ActorFields } createdAt requestedReviewer { __typename ... on User { login } ... on Team { slug } } }
      ... on ReadyForReviewEvent { actor { ...ActorFields } createdAt }
      ... on AssignedEvent { actor { ...ActorFields } createdAt assignee { __typename ... on User { login } } }
      ... on HeadRefForcePushedEvent { actor { ...ActorFields } createdAt }
    }
    """

    static func query(for requests: [Request]) -> String {
        let aliases = requests.enumerated().map { index, request in
            "s\(index): repository(owner: \(request.owner.graphQLQuoted), name: \(request.name.graphQLQuoted)) { issueOrPullRequest(number: \(request.number)) { ...SubjectFields } }"
        }
        return """
        query {
        \(aliases.joined(separator: "\n"))
        }
        \(actorFragment)
        \(pullRequestTimelineFragment)
        fragment SubjectFields on IssueOrPullRequest {
          __typename
          ... on PullRequest {
            prState: state
            isDraft
            comments { totalCount }
            prTimeline: timelineItems(last: 6, itemTypes: [ISSUE_COMMENT, PULL_REQUEST_REVIEW, PULL_REQUEST_COMMIT, MERGED_EVENT, CLOSED_EVENT, REOPENED_EVENT, REVIEW_REQUESTED_EVENT, READY_FOR_REVIEW_EVENT, ASSIGNED_EVENT, HEAD_REF_FORCE_PUSHED_EVENT]) {
              nodes { ...PullRequestTimelineFields }
            }
          }
          ... on Issue {
            issueState: state
            stateReason
            comments { totalCount }
            issueTimeline: timelineItems(last: 6, itemTypes: [ISSUE_COMMENT, CLOSED_EVENT, REOPENED_EVENT, ASSIGNED_EVENT]) {
              nodes {
                __typename
                ... on IssueComment { author { ...ActorFields } createdAt url }
                ... on ClosedEvent { actor { ...ActorFields } createdAt }
                ... on ReopenedEvent { actor { ...ActorFields } createdAt }
                ... on AssignedEvent { actor { ...ActorFields } createdAt assignee { __typename ... on User { login } } }
              }
            }
          }
        }
        """
    }

    // MARK: - Decoding

    struct RepositoryNode: Decodable {
        let issueOrPullRequest: SubjectNode?
    }

    struct SubjectNode: Decodable {
        let state: SubjectState
        let commentCount: Int
        let timeline: [TimelineNode]

        private enum CodingKeys: String, CodingKey {
            case typename = "__typename"
            case prState, isDraft, comments, prTimeline, issueState, stateReason, issueTimeline
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            commentCount = try container.decodeIfPresent(TotalCount.self, forKey: .comments)?.totalCount ?? 0
            if try container.decode(String.self, forKey: .typename) == "PullRequest" {
                let isDraft = try container.decodeIfPresent(Bool.self, forKey: .isDraft) ?? false
                state = switch try container.decode(String.self, forKey: .prState) {
                case "MERGED": .merged
                case "CLOSED": .closed
                default: isDraft ? .draft : .open
                }
                timeline = try container.decodeIfPresent(Nodes<TimelineNode>.self, forKey: .prTimeline)?.nodes ?? []
            } else {
                let reason = try container.decodeIfPresent(String.self, forKey: .stateReason)
                state = switch try container.decode(String.self, forKey: .issueState) {
                case "CLOSED": reason == "NOT_PLANNED" || reason == "DUPLICATE" ? .closedNotPlanned : .closed
                default: .open
                }
                timeline = try container.decodeIfPresent(Nodes<TimelineNode>.self, forKey: .issueTimeline)?.nodes ?? []
            }
        }
    }

    struct TimelineNode: Decodable {
        let event: TimelineEvent?

        private enum CodingKeys: String, CodingKey {
            case typename = "__typename"
            case author, actor, createdAt, submittedAt, url, state, commit, assignee, requestedReviewer
        }

        private struct Target: Decodable {
            let login: String?
            let slug: String?
        }

        private struct Commit: Decodable {
            let committedDate: Date
            let authors: Nodes<CommitAuthor>
        }

        private struct CommitAuthor: Decodable {
            let user: Actor?
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let typename = try container.decode(String.self, forKey: .typename)
            let actor = try container.decodeIfPresent(Actor.self, forKey: .actor)
            let createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
            let url = try container.decodeIfPresent(URL.self, forKey: .url)

            func withTarget(_ event: TimelineEvent, _ target: String?) -> TimelineEvent {
                var event = event
                event.target = target
                return event
            }

            func make(_ kind: TimelineEvent.Kind, by actor: Actor? = actor, at date: Date? = createdAt) -> TimelineEvent? {
                date.map { TimelineEvent(kind: kind, actor: actor, date: $0, url: url) }
            }

            switch typename {
            case "IssueComment":
                event = make(.commented, by: try container.decodeIfPresent(Actor.self, forKey: .author))
            case "PullRequestReview":
                let kind: TimelineEvent.Kind? = switch try container.decodeIfPresent(String.self, forKey: .state) {
                case "APPROVED": .approved
                case "CHANGES_REQUESTED": .changesRequested
                case "COMMENTED", "DISMISSED": .reviewed
                default: nil // pending reviews are drafts nobody else can see
                }
                let submittedAt = try container.decodeIfPresent(Date.self, forKey: .submittedAt) ?? createdAt
                event = kind.flatMap { make($0, by: try? container.decodeIfPresent(Actor.self, forKey: .author), at: submittedAt) }
            case "PullRequestCommit":
                let commit = try container.decodeIfPresent(Commit.self, forKey: .commit)
                event = commit.flatMap { make(.committed, by: $0.authors.nodes.first?.user, at: $0.committedDate) }
            case "MergedEvent": event = make(.merged)
            case "ClosedEvent": event = make(.closed)
            case "ReopenedEvent": event = make(.reopened)
            case "ReviewRequestedEvent":
                let reviewer = try container.decodeIfPresent(Target.self, forKey: .requestedReviewer)
                event = make(.reviewRequested).map { withTarget($0, reviewer?.login ?? reviewer?.slug) }
            case "ReadyForReviewEvent": event = make(.readyForReview)
            case "AssignedEvent":
                let assignee = try container.decodeIfPresent(Target.self, forKey: .assignee)
                event = make(.assigned).map { withTarget($0, assignee?.login) }
            case "HeadRefForcePushedEvent": event = make(.forcePushed)
            default: event = nil
            }
        }
    }
}

nonisolated struct TotalCount: Decodable, Sendable {
    let totalCount: Int
}

nonisolated struct Nodes<Node: Decodable>: Decodable {
    let nodes: [Node]

    private enum CodingKeys: String, CodingKey { case nodes }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // GraphQL returns null entries for nodes the token cannot see.
        nodes = try container.decodeIfPresent([Node?].self, forKey: .nodes)?.compactMap { $0 } ?? []
    }
}
