import Foundation

/// Whose notifications the Inbox shows.
nonisolated enum ActorFilter: String, CaseIterable, Identifiable, Sendable {
    case all, people, bots

    var id: Self { self }

    var label: String {
        switch self {
        case .all: "All"
        case .people: "People"
        case .bots: "Bots"
        }
    }

    var explanation: String {
        switch self {
        case .all: "Notifications from people and bots"
        case .people: "The latest activity is by a person"
        case .bots: "By a bot or app, or by no one (CI, releases, alerts)"
        }
    }
}

/// The Inbox filters. They combine: every active filter has to match.
nonisolated enum InboxFilter {
    /// Whether a person caused the latest activity. GitHub Apps (github-actions, dependabot, renovate…)
    /// have their own actor type; machine users only give themselves away by name, see `Actor.isBot`.
    /// Threads without an actor (releases, CI runs, security alerts, details not loaded yet) aren't.
    /// `overrides` are corrections by login (lowercased), true for bots; they win over the detection.
    static func isFromPerson(_ details: SubjectDetails?, overrides: [String: Bool] = [:]) -> Bool {
        guard let actor = details?.latestEvent?.actor else { return false }
        return !actor.isBot(overrides: overrides)
    }

    /// Merged or closed pull requests and closed issues: nothing left to do there.
    static func isFinished(_ details: SubjectDetails?) -> Bool {
        switch details?.state {
        case .merged?, .closed?, .closedNotPlanned?: true
        default: false
        }
    }

    static func matches(
        _ details: SubjectDetails?, actor filter: ActorFilter, finishedOnly: Bool, overrides: [String: Bool] = [:]
    ) -> Bool {
        if finishedOnly && !isFinished(details) { return false }
        switch filter {
        case .all: return true
        case .people: return isFromPerson(details, overrides: overrides)
        case .bots: return !isFromPerson(details, overrides: overrides)
        }
    }
}
