import Foundation

nonisolated protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

nonisolated struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    /// API traffic must never be answered from a local cache: GitHub sends `max-age=60`,
    /// which would otherwise hide new notifications and swallow our 304 handling.
    static let api: URLSessionTransport = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        return URLSessionTransport(session: URLSession(configuration: configuration))
    }()

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

nonisolated enum GitHubError: Error, Equatable, Sendable {
    case unauthorized
    case rateLimited(resetAt: Date?)
    case http(status: Int, message: String?)
    case graphQL(messages: [String])
    case offline
    case network(String)
    case decoding(String)
}

extension GitHubError: LocalizedError {
    nonisolated var errorDescription: String? {
        switch self {
        case .unauthorized:
            "Your GitHub session expired. Please sign in again."
        case .rateLimited(let resetAt):
            if let resetAt {
                "GitHub rate limit reached. Resets at \(resetAt.formatted(date: .omitted, time: .shortened))."
            } else {
                "GitHub rate limit reached."
            }
        case .http(let status, let message):
            "GitHub returned \(status)\(message.map { ": \($0)" } ?? "")."
        case .graphQL(let messages):
            messages.first ?? "GitHub returned an error."
        case .offline:
            "You're offline."
        case .network(let message):
            message
        case .decoding(let message):
            "Unexpected response from GitHub (\(message))."
        }
    }
}

nonisolated struct GitHubResponse: Sendable {
    let data: Data
    let http: HTTPURLResponse

    var statusCode: Int { http.statusCode }
    var isNotModified: Bool { http.statusCode == 304 }
    var pollInterval: Int? { http.value(forHTTPHeaderField: "X-Poll-Interval").flatMap(Int.init) }
    var lastModified: String? { http.value(forHTTPHeaderField: "Last-Modified") }
    var nextPageURL: URL? { http.value(forHTTPHeaderField: "Link").flatMap(Self.nextLink(in:)) }

    /// Parses `<https://…?page=2>; rel="next", <…>; rel="last"`.
    static func nextLink(in header: String) -> URL? {
        for part in header.split(separator: ",") {
            let segments = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard segments.count >= 2, segments.dropFirst().contains("rel=\"next\"") else { continue }
            let raw = segments[0].trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            return URL(string: raw)
        }
        return nil
    }
}

nonisolated struct GraphQLErrorItem: Decodable, Sendable {
    let message: String
    let type: String?
}

nonisolated struct GitHubClient: Sendable {
    static let apiBase = URL(string: "https://api.github.com")!

    let token: String
    var transport: any HTTPTransport = URLSessionTransport.api

    static let restDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    func request(
        _ method: String = "GET",
        url: URL,
        headers: [String: String] = [:],
        body: Data? = nil
    ) async throws -> GitHubResponse {
        var request = URLRequest(url: url)
        request.httpMethod = method
        // Pagination links and subject URLs come from responses: the token only ever goes to GitHub's API.
        if url.host() == Self.apiBase.host() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch let error as URLError {
            Log.info(.github, "\(method) \(Self.logPath(of: url)) failed: \(error.localizedDescription)")
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                throw GitHubError.offline
            default:
                throw GitHubError.network(error.localizedDescription)
            }
        }
        guard let http = response as? HTTPURLResponse else {
            throw GitHubError.network("Invalid response")
        }
        do {
            try Self.validate(http, data: data)
        } catch {
            // Callers decide whether it's a failure: a 404 for stacks only means the repository has none.
            Log.info(.github, "\(method) \(Self.logPath(of: url)) → \(http.statusCode): \(error.localizedDescription)")
            throw error
        }
        return GitHubResponse(data: data, http: http)
    }

    /// "/notifications?all=true", without the host.
    private static func logPath(of url: URL) -> String {
        url.path(percentEncoded: false) + (url.query(percentEncoded: false).map { "?\($0)" } ?? "")
    }

    func rest(_ method: String = "GET", path: String, body: Data? = nil) async throws -> GitHubResponse {
        try await request(method, url: Self.apiBase.appending(path: path), body: body)
    }

    func decode<T: Decodable>(_ type: T.Type, from response: GitHubResponse) throws -> T {
        do {
            return try Self.restDecoder.decode(type, from: response.data)
        } catch {
            throw GitHubError.decoding(String(describing: error))
        }
    }

    /// Runs a GraphQL query. Partial errors (e.g. one inaccessible repository) are returned
    /// alongside the data instead of failing the whole request.
    func graphQL<D: Decodable>(
        _ query: String,
        variables: [String: String] = [:],
        as type: D.Type
    ) async throws -> (data: D, errors: [GraphQLErrorItem]) {
        let body = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let response = try await request("POST", url: Self.apiBase.appending(path: "graphql"), body: body)
        let envelope: GraphQLEnvelope<D>
        do {
            envelope = try Self.restDecoder.decode(GraphQLEnvelope<D>.self, from: response.data)
        } catch {
            throw GitHubError.decoding(String(describing: error))
        }
        let errors = envelope.errors ?? []
        guard let data = envelope.data else {
            if errors.contains(where: { $0.type == "RATE_LIMITED" }) {
                throw GitHubError.rateLimited(resetAt: nil)
            }
            throw GitHubError.graphQL(messages: errors.map(\.message))
        }
        return (data, errors)
    }

    static func validate(_ http: HTTPURLResponse, data: Data) throws {
        switch http.statusCode {
        case 200..<300, 304:
            return
        case 401:
            throw GitHubError.unauthorized
        default:
            let isRateLimited = http.statusCode == 429
                || (http.statusCode == 403 && http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0")
            if isRateLimited {
                let reset = http.value(forHTTPHeaderField: "X-RateLimit-Reset")
                    .flatMap(TimeInterval.init)
                    .map(Date.init(timeIntervalSince1970:))
                throw GitHubError.rateLimited(resetAt: reset)
            }
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.message
            throw GitHubError.http(status: http.statusCode, message: message)
        }
    }

    private struct ErrorBody: Decodable {
        let message: String
    }

    private struct GraphQLEnvelope<D: Decodable>: Decodable {
        let data: D?
        let errors: [GraphQLErrorItem]?
    }
}

nonisolated extension String {
    /// Quotes a value for direct inclusion in a GraphQL document.
    var graphQLQuoted: String {
        let data = try? JSONSerialization.data(withJSONObject: self, options: .fragmentsAllowed)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }
}
