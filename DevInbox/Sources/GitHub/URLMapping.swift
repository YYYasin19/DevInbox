import Foundation

/// Maps the API URLs in notifications to the pages a browser should open.
nonisolated enum URLMapping {
    static let web = URL(string: "https://github.com")!

    enum Target: Equatable {
        case browser(URL)
        /// The browser URL is only available from the API resource (e.g. releases).
        case resolve(api: URL, fallback: URL)
    }

    static func target(for thread: NotificationThread) -> Target {
        let repo = thread.repository
        let repoURL = web.appending(path: repo.fullName)
        let subject = thread.subject

        switch subject.type {
        case .issue, .pullRequest, .commit:
            guard let apiURL = subject.url, var page = htmlURL(forAPIURL: apiURL) else {
                return .browser(repoURL)
            }
            if let anchor = commentAnchor(latestCommentURL: subject.latestCommentURL, subjectURL: subject.url) {
                page = page.withFragment(anchor)
            }
            return .browser(page)
        case .release:
            guard let apiURL = subject.url else { return .browser(repoURL.appending(path: "releases")) }
            return .resolve(api: apiURL, fallback: repoURL.appending(path: "releases"))
        case .discussion:
            var components = URLComponents(url: repoURL.appending(path: "discussions"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "discussions_q", value: subject.title)]
            return .browser(components.url ?? repoURL)
        case .checkSuite:
            return .browser(repoURL.appending(path: "actions"))
        case .dependabotAlerts, .vulnerabilityAlert:
            return .browser(repoURL.appending(path: "security/dependabot"))
        case .advisory:
            return .browser(repoURL.appending(path: "security/advisories"))
        default:
            return .browser(repoURL)
        }
    }

    /// `api.github.com/repos/o/r/pulls/7` → `github.com/o/r/pull/7` (same for issues and commits).
    static func htmlURL(forAPIURL url: URL) -> URL? {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 5, parts[0] == "repos" else { return nil }
        let owner = parts[1], repo = parts[2], kind = parts[3], id = parts[4]
        let webKind: String
        switch kind {
        case "pulls": webKind = "pull"
        case "issues": webKind = "issues"
        case "commits": webKind = "commit"
        default: return nil
        }
        return web.appending(path: "\(owner)/\(repo)/\(webKind)/\(id)")
    }

    /// Fragment that jumps to the latest comment, if the notification points at one.
    static func commentAnchor(latestCommentURL: URL?, subjectURL: URL?) -> String? {
        guard let latestCommentURL, latestCommentURL != subjectURL else { return nil }
        let parts = latestCommentURL.pathComponents.filter { $0 != "/" }
        guard parts.count >= 6, parts[0] == "repos", parts[4] == "comments" else { return nil }
        let id = parts[5]
        switch parts[3] {
        case "issues": return "issuecomment-\(id)"
        case "pulls": return "discussion_r\(id)"
        default: return nil
        }
    }
}

nonisolated extension URL {
    func withFragment(_ fragment: String) -> URL {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        components?.fragment = fragment
        return components?.url ?? self
    }

    /// GitHub avatar URLs accept a size parameter; smaller images load faster in lists.
    func avatarSized(_ points: Int) -> URL {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        var items = components?.queryItems ?? []
        items.removeAll { $0.name == "s" }
        items.append(URLQueryItem(name: "s", value: String(points * 2)))
        components?.queryItems = items
        return components?.url ?? self
    }
}
