import Foundation

nonisolated struct NotificationsAPI: Sendable {
    let client: GitHubClient

    enum FetchResult: Sendable {
        case notModified(pollInterval: Int?)
        case updated(threads: [NotificationThread], lastModified: String?, pollInterval: Int?)
    }

    /// Fetches the inbox (read and unread, like github.com/notifications).
    /// `ifModifiedSince` makes unchanged polls free: GitHub answers 304 without counting against the rate limit.
    /// When something did change, GitHub answers with only the notifications updated since then, not the
    /// inbox, so a changed conditional poll fetches the whole inbox again.
    func fetch(ifModifiedSince: String?, maxPages: Int = 4) async throws -> FetchResult {
        let firstURL = GitHubClient.apiBase.appending(path: "notifications")
            .appending(queryItems: [URLQueryItem(name: "all", value: "true"), URLQueryItem(name: "per_page", value: "50")])
        var headers: [String: String] = [:]
        if let ifModifiedSince {
            headers["If-Modified-Since"] = ifModifiedSince
        }

        let first = try await client.request(url: firstURL, headers: headers)
        if first.isNotModified {
            return .notModified(pollInterval: first.pollInterval)
        }
        if ifModifiedSince != nil {
            return try await fetch(ifModifiedSince: nil, maxPages: maxPages)
        }

        var threads = try client.decode([NotificationThread].self, from: first)
        var next = first.nextPageURL
        var pages = 1
        while let url = next, pages < maxPages {
            let page = try await client.request(url: url)
            threads += try client.decode([NotificationThread].self, from: page)
            next = page.nextPageURL
            pages += 1
        }
        // Past the newest read and unread threads, unread ones still belong in the inbox and its count.
        if next != nil {
            threads += try await fetchUnread()
        }
        // New notifications arriving mid-fetch shift the pages and repeat threads; keep the first copy.
        var seen = Set<String>()
        threads = threads.filter { seen.insert($0.id).inserted }
        return .updated(threads: threads, lastModified: first.lastModified, pollInterval: first.pollInterval)
    }

    /// Unread threads only, which GitHub returns by default.
    private func fetchUnread(maxPages: Int = 10) async throws -> [NotificationThread] {
        var next: URL? = GitHubClient.apiBase.appending(path: "notifications")
            .appending(queryItems: [URLQueryItem(name: "per_page", value: "50")])
        var threads: [NotificationThread] = []
        var pages = 0
        while let url = next, pages < maxPages {
            let page = try await client.request(url: url)
            threads += try client.decode([NotificationThread].self, from: page)
            next = page.nextPageURL
            pages += 1
        }
        return threads
    }

    func markRead(threadID: String) async throws {
        _ = try await client.rest("PATCH", path: "notifications/threads/\(threadID)")
    }

    /// Same as "Done" on github.com: removes the thread from the inbox there. `fetch` keeps listing it.
    func markDone(threadID: String) async throws {
        _ = try await client.rest("DELETE", path: "notifications/threads/\(threadID)")
    }

    /// Resolves the browser URL of an API resource (used for releases).
    func htmlURL(forAPIResource url: URL) async throws -> URL? {
        struct Resource: Decodable {
            let html_url: URL?
        }
        let response = try await client.request(url: url)
        return try client.decode(Resource.self, from: response).html_url
    }

    func viewer() async throws -> Viewer {
        try client.decode(Viewer.self, from: try await client.rest(path: "user"))
    }
}
