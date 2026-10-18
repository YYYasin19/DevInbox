import Foundation

nonisolated struct Actor: Decodable, Hashable, Sendable {
    let login: String
    let avatarUrl: URL?
    /// GraphQL's `__typename`: "Bot" for GitHub Apps, "User" for accounts, nil where not fetched.
    var typename: String? = nil
    /// The profile's display name, for users.
    var name: String? = nil

    private enum CodingKeys: String, CodingKey {
        case login, avatarUrl, name
        case typename = "__typename"
    }

    /// GitHub Apps are their own type. Machine users are ordinary accounts that only give themselves
    /// away by their login ("regro-cf-autotick-bot") or display name ("automatic conda-forge
    /// administrator").
    var isBot: Bool {
        if typename == "Bot" { return true }
        let login = login.lowercased()
        if login.hasSuffix("[bot]") || login.hasSuffix("-bot") || login.hasSuffix("_bot") { return true }
        return name?.lowercased().split(whereSeparator: { !$0.isLetter }).contains(where: Self.botWords.contains) ?? false
    }

    /// `isBot`, unless the login was corrected in the Inbox: `overrides` are by lowercased login, true for bots.
    func isBot(overrides: [String: Bool]) -> Bool {
        overrides[login.lowercased()] ?? isBot
    }

    private static let botWords: Set<Substring> = ["bot", "robot", "automatic", "automated", "automation"]
}

nonisolated enum SubjectState: Hashable, Sendable {
    case open, draft, merged, closed, closedNotPlanned
}

/// The most recent thing that happened on an issue or pull request.
nonisolated struct TimelineEvent: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case commented, approved, changesRequested, reviewed, committed, merged, closed, reopened
        case reviewRequested, readyForReview, assigned, forcePushed
        /// An answer in a review thread you started.
        case replied
    }

    let kind: Kind
    let actor: Actor?
    let date: Date
    let url: URL?
    /// Assignee or requested reviewer (user login or team slug), if any.
    var target: String? = nil

    /// What the actor did, phrased from the viewer's perspective ("requested your review").
    func verb(viewer: String) -> String {
        let targetIsViewer = target?.caseInsensitiveCompare(viewer) == .orderedSame
        return switch kind {
        case .commented: "commented"
        case .approved: "approved"
        case .changesRequested: "requested changes"
        case .reviewed: "reviewed"
        case .committed: "pushed a commit"
        case .merged: "merged"
        case .closed: "closed"
        case .reopened: "reopened"
        case .reviewRequested:
            targetIsViewer ? "requested your review" : target.map { "requested review from @\($0)" } ?? "requested a review"
        case .readyForReview: "marked ready for review"
        case .assigned:
            targetIsViewer ? "assigned you" : target.map { "assigned @\($0)" } ?? "assigned someone"
        case .forcePushed: "force-pushed"
        case .replied: "replied to your comment"
        }
    }

    /// Picks the event that best explains the notification: the latest one by someone other than
    /// the viewer (your own activity never notifies you), falling back to the latest overall.
    /// For merged pull requests the "closed" event GitHub emits alongside "merged" is ignored.
    static func latestRelevant(in events: [TimelineEvent], viewer: String, merged: Bool) -> TimelineEvent? {
        let candidates = events
            .filter { !(merged && $0.kind == .closed) }
            .sorted { $0.date < $1.date }
        let byOthers = candidates.last { $0.actor.map { $0.login.caseInsensitiveCompare(viewer) != .orderedSame } ?? true }
        return byOthers ?? candidates.last
    }
}

nonisolated struct SubjectDetails: Hashable, Sendable {
    let state: SubjectState
    let commentCount: Int
    let latestEvent: TimelineEvent?
}
