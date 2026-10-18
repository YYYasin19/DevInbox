import Foundation

@Observable
final class AppSettings {
    enum InboxGrouping: String, CaseIterable, Identifiable {
        case repository, chronological

        var id: Self { self }
        var label: String {
            switch self {
            case .repository: "By repository"
            case .chronological: "Chronological"
            }
        }
    }

    @ObservationIgnored private let defaults: UserDefaults

    var inboxGrouping: InboxGrouping {
        didSet { defaults.set(inboxGrouping.rawValue, forKey: Keys.inboxGrouping) }
    }

    var actorFilter: ActorFilter {
        didSet { defaults.set(actorFilter.rawValue, forKey: Keys.actorFilter) }
    }

    /// Accounts you marked as bot (true) or person (false), by lowercased login.
    var actorOverrides: [String: Bool] {
        didSet { defaults.set(actorOverrides, forKey: Keys.actorOverrides) }
    }

    /// Only merged or closed pull requests and closed issues.
    var finishedOnly: Bool {
        didSet { defaults.set(finishedOnly, forKey: Keys.finishedOnly) }
    }

    var showUnreadCount: Bool {
        didSet { defaults.set(showUnreadCount, forKey: Keys.showUnreadCount) }
    }

    /// The history below the waiting reviews is unfolded.
    var showsReviewHistory: Bool {
        didSet { defaults.set(showsReviewHistory, forKey: Keys.showsReviewHistory) }
    }

    /// Repositories collapsed in the grouped Inbox, by full name.
    var collapsedRepositories: Set<String> {
        didSet { defaults.set(collapsedRepositories.sorted(), forKey: Keys.collapsedRepositories) }
    }

    var dateFormat: DateFormat {
        didSet { defaults.set(dateFormat.rawValue, forKey: Keys.dateFormat) }
    }

    var showsReviewDot: Bool {
        didSet { defaults.set(showsReviewDot, forKey: Keys.showsReviewDot) }
    }

    var bannerReasons: Set<NotificationReason> {
        didSet { defaults.set(bannerReasons.map(\.rawValue).sorted(), forKey: Keys.bannerReasons) }
    }

    /// Opens the panel from any app, even when the menu bar has no room for DevInbox. Nil when turned off.
    var openPanelShortcut: Shortcut? {
        didSet { defaults.set(try? JSONEncoder().encode(openPanelShortcut), forKey: Keys.openPanelShortcut) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        inboxGrouping = defaults.string(forKey: Keys.inboxGrouping).flatMap(InboxGrouping.init(rawValue:)) ?? .repository
        actorFilter = defaults.string(forKey: Keys.actorFilter).flatMap(ActorFilter.init(rawValue:)) ?? .all
        finishedOnly = defaults.bool(forKey: Keys.finishedOnly)
        actorOverrides = defaults.dictionary(forKey: Keys.actorOverrides) as? [String: Bool] ?? [:]
        showUnreadCount = defaults.object(forKey: Keys.showUnreadCount) as? Bool ?? true
        showsReviewDot = defaults.object(forKey: Keys.showsReviewDot) as? Bool ?? true
        dateFormat = defaults.string(forKey: Keys.dateFormat).flatMap(DateFormat.init(rawValue:)) ?? .monthDay
        collapsedRepositories = Set(defaults.stringArray(forKey: Keys.collapsedRepositories) ?? [])
        showsReviewHistory = defaults.bool(forKey: Keys.showsReviewHistory)
        bannerReasons = (defaults.stringArray(forKey: Keys.bannerReasons))
            .map { Set($0.map(NotificationReason.init(rawValue:))) } ?? NotificationReason.defaultBannerReasons
        openPanelShortcut = if let data = defaults.data(forKey: Keys.openPanelShortcut) {
            (try? JSONDecoder().decode(Shortcut?.self, from: data)) ?? .openPanel
        } else {
            .openPanel
        }
    }

    private enum Keys {
        static let inboxGrouping = "inboxGrouping"
        static let actorFilter = "actorFilter"
        static let finishedOnly = "finishedOnly"
        static let actorOverrides = "actorOverrides"
        static let showUnreadCount = "showUnreadCount"
        static let showsReviewDot = "showsReviewDot"
        static let dateFormat = "dateFormat"
        static let collapsedRepositories = "collapsedRepositories"
        static let showsReviewHistory = "showsReviewHistory"
        static let bannerReasons = "bannerReasons"
        static let openPanelShortcut = "openPanelShortcut"
    }
}
