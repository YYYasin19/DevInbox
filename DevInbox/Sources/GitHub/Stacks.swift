import Foundation

nonisolated struct StackInfo: Hashable, Sendable {
    struct Entry: Hashable, Sendable {
        enum State: Hashable, Sendable { case open, draft, merged, closed }

        let number: Int
        let state: State
    }

    /// Bottom (closest to the trunk) to top.
    let entries: [Entry]
    /// 1-based position of the pull request this info was resolved for.
    let position: Int
    let isNative: Bool

    var count: Int { entries.count }
}

/// GitHub's native stacks API (the one `gh stack` uses).
nonisolated enum StacksAPI {
    struct Stack: Decodable {
        let number: Int
        let pull_requests: [PullRequest]

        struct PullRequest: Decodable {
            let number: Int
            let state: String
            let draft: Bool
            let merged_at: Date?
        }
    }

    enum Lookup: Sendable {
        case stack(StackInfo?)
        /// The repository doesn't support stacks (or the token can't see them).
        case unsupported
    }

    static func stack(repository: String, number: Int, client: GitHubClient) async throws -> Lookup {
        let url = GitHubClient.apiBase.appending(path: "repos/\(repository)/stacks")
            .appending(queryItems: [URLQueryItem(name: "pull_request", value: String(number))])
        let response: GitHubResponse
        do {
            response = try await client.request(url: url)
        } catch GitHubError.http(let status, _) where status == 404 || status == 403 {
            return .unsupported
        }
        let stacks = try client.decode([Stack].self, from: response)
        return .stack(StackResolver.fromNative(stacks, number: number))
    }
}

nonisolated enum StackResolver {
    static func fromNative(_ stacks: [StacksAPI.Stack], number: Int) -> StackInfo? {
        for stack in stacks {
            guard let index = stack.pull_requests.firstIndex(where: { $0.number == number }),
                  stack.pull_requests.count > 1 else { continue }
            let entries = stack.pull_requests.map { pr in
                StackInfo.Entry(
                    number: pr.number,
                    state: pr.merged_at != nil ? .merged : pr.state == "closed" ? .closed : pr.draft ? .draft : .open
                )
            }
            return StackInfo(entries: entries, position: index + 1, isNative: true)
        }
        return nil
    }

    /// Fallback for stacks GitHub doesn't know about: follows base → head branch links between
    /// open pull requests of the same repository.
    static func fromBranches(for pullRequest: PullRequestSummary, among candidates: [PullRequestSummary]) -> StackInfo? {
        let sameRepository = candidates.filter { $0.repository == pullRequest.repository }
        // A fork's head branch (e.g. `contributor:main`) isn't a branch of this repository, so it
        // can't be the base of another pull request here.
        let byHead = Dictionary(
            sameRepository.filter { !$0.isCrossRepository }.map { ($0.headRefName, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var below: [PullRequestSummary] = []
        var cursor = pullRequest
        var visited: Set<String> = [pullRequest.id]
        while let parent = byHead[cursor.baseRefName], visited.insert(parent.id).inserted {
            below.insert(parent, at: 0)
            cursor = parent
        }

        var above: [PullRequestSummary] = []
        cursor = pullRequest
        while !cursor.isCrossRepository,
              let child = sameRepository
                  .filter({ $0.baseRefName == cursor.headRefName })
                  .min(by: { $0.number < $1.number }),
              visited.insert(child.id).inserted {
            above.append(child)
            cursor = child
        }

        let chain = below + [pullRequest] + above
        guard chain.count > 1 else { return nil }
        return StackInfo(
            entries: chain.map { StackInfo.Entry(number: $0.number, state: $0.isDraft ? .draft : .open) },
            position: below.count + 1,
            isNative: false
        )
    }
}
