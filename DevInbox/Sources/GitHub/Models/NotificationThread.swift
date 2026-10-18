import Foundation

nonisolated struct NotificationThread: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    var unread: Bool
    let reason: NotificationReason
    let updatedAt: Date
    let lastReadAt: Date?
    let subject: Subject
    let repository: Repository

    nonisolated struct Subject: Decodable, Hashable, Sendable {
        let title: String
        let url: URL?
        let latestCommentURL: URL?
        let type: SubjectType

        enum CodingKeys: String, CodingKey {
            case title, url, type
            case latestCommentURL = "latest_comment_url"
        }
    }

    nonisolated struct Repository: Decodable, Hashable, Sendable {
        let fullName: String
        let htmlURL: URL
        let owner: Owner

        nonisolated struct Owner: Decodable, Hashable, Sendable {
            let login: String
            let avatarURL: URL?

            enum CodingKeys: String, CodingKey {
                case login
                case avatarURL = "avatar_url"
            }
        }

        enum CodingKeys: String, CodingKey {
            case owner
            case fullName = "full_name"
            case htmlURL = "html_url"
        }

        var name: String { String(fullName.split(separator: "/").last ?? "") }
    }

    enum CodingKeys: String, CodingKey {
        case id, unread, reason, subject, repository
        case updatedAt = "updated_at"
        case lastReadAt = "last_read_at"
    }

    /// Issue / pull request number, parsed from the subject's API URL.
    var number: Int? {
        guard subject.type == .issue || subject.type == .pullRequest,
              let last = subject.url?.lastPathComponent else { return nil }
        return Int(last)
    }

    /// "owner/repo#123", matching `PullRequestSummary.subjectKey`.
    var subjectKey: String? {
        number.map { "\(repository.fullName)#\($0)" }
    }

    /// "acme/api#12" or "acme/api: Release 1.2", to tell threads apart in the log.
    var logName: String {
        subjectKey ?? "\(repository.fullName): \(subject.title)"
    }
}

nonisolated struct NotificationReason: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static let approvalRequested = Self(rawValue: "approval_requested")
    static let assign = Self(rawValue: "assign")
    static let author = Self(rawValue: "author")
    static let ciActivity = Self(rawValue: "ci_activity")
    static let comment = Self(rawValue: "comment")
    static let invitation = Self(rawValue: "invitation")
    static let manual = Self(rawValue: "manual")
    static let memberFeatureRequested = Self(rawValue: "member_feature_requested")
    static let mention = Self(rawValue: "mention")
    static let reviewRequested = Self(rawValue: "review_requested")
    static let securityAdvisoryCredit = Self(rawValue: "security_advisory_credit")
    static let securityAlert = Self(rawValue: "security_alert")
    static let stateChange = Self(rawValue: "state_change")
    static let subscribed = Self(rawValue: "subscribed")
    static let teamMention = Self(rawValue: "team_mention")

    /// Reasons that can trigger a macOS banner, in the order shown in Settings.
    static let bannerCandidates: [Self] = [
        .reviewRequested, .mention, .teamMention, .assign, .author, .comment,
        .stateChange, .ciActivity, .securityAlert, .approvalRequested, .subscribed,
    ]

    static let defaultBannerReasons: Set<Self> = [.reviewRequested, .mention, .teamMention, .assign]

    var label: String {
        switch self {
        case .approvalRequested: "Approval requested"
        case .assign: "Assigned"
        case .author: "Author"
        case .ciActivity: "CI activity"
        case .comment: "Commented"
        case .invitation: "Invitation"
        case .manual: "Subscribed manually"
        case .memberFeatureRequested: "Feature request"
        case .mention: "Mentioned"
        case .reviewRequested: "Review requested"
        case .securityAdvisoryCredit: "Advisory credit"
        case .securityAlert: "Security alert"
        case .stateChange: "State change"
        case .subscribed: "Watching"
        case .teamMention: "Team mentioned"
        default: rawValue.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Explains why the notification arrived, shown as a tooltip on the reason chip.
    var explanation: String {
        switch self {
        case .approvalRequested: "You were asked to approve a deployment."
        case .assign: "You were assigned to this."
        case .author: "You opened this thread."
        case .ciActivity: "A GitHub Actions workflow run you triggered finished."
        case .comment: "You commented on this thread."
        case .invitation: "You were invited to contribute to the repository."
        case .manual: "You subscribed to this thread manually."
        case .memberFeatureRequested: "A member asked for a feature to be enabled."
        case .mention: "You were @mentioned."
        case .reviewRequested: "You, or a team you're on, were asked to review this pull request."
        case .securityAdvisoryCredit: "You were credited for a security advisory."
        case .securityAlert: "GitHub found a security vulnerability in the repository."
        case .stateChange: "You changed the state of this thread (e.g. closed or merged it)."
        case .subscribed: "You're watching the repository."
        case .teamMention: "A team you're on was @mentioned."
        default: "GitHub reason: \(rawValue)"
        }
    }

    var isImportant: Bool {
        [.reviewRequested, .mention, .teamMention, .assign, .securityAlert].contains(self)
    }
}

nonisolated struct SubjectType: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static let issue = Self(rawValue: "Issue")
    static let pullRequest = Self(rawValue: "PullRequest")
    static let release = Self(rawValue: "Release")
    static let discussion = Self(rawValue: "Discussion")
    static let commit = Self(rawValue: "Commit")
    static let checkSuite = Self(rawValue: "CheckSuite")
    static let dependabotAlerts = Self(rawValue: "RepositoryDependabotAlertsThread")
    static let vulnerabilityAlert = Self(rawValue: "RepositoryVulnerabilityAlert")
    static let advisory = Self(rawValue: "RepositoryAdvisory")

    var label: String {
        switch self {
        case .issue: "Issue"
        case .pullRequest: "Pull request"
        case .release: "Release"
        case .discussion: "Discussion"
        case .commit: "Commit"
        case .checkSuite: "Workflow run"
        case .dependabotAlerts, .vulnerabilityAlert: "Dependabot alert"
        case .advisory: "Security advisory"
        default: rawValue
        }
    }
}

nonisolated struct Viewer: Codable, Hashable, Sendable {
    let login: String
    let name: String?
    let avatarURL: URL?

    enum CodingKeys: String, CodingKey {
        case login, name
        case avatarURL = "avatar_url"
    }
}
