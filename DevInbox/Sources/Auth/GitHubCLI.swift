import Foundation

/// DevInbox borrows the GitHub CLI's login instead of running its own OAuth flow:
/// no client secret, no app registration, and organizations usually allow the CLI already.
/// The token is read on demand and never stored by DevInbox.
nonisolated enum GitHubCLI {
    /// OAuth client ID of the GitHub CLI, for linking to its organization access settings.
    static let oauthClientID = "178c6fc778ccc68e1d6a"
    static let connectionsURL = URL(string: "https://github.com/settings/connections/applications/\(oauthClientID)")!

    static let installCommand = "brew install gh"
    static let loginCommand = "gh auth login"

    enum TokenError: Error, Equatable, LocalizedError {
        case notInstalled
        case notLoggedIn
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled: "The GitHub CLI (gh) isn't installed."
            case .notLoggedIn: "The GitHub CLI isn't logged in to github.com."
            case .failed(let message): message
            }
        }
    }

    static func token() async throws -> String {
        guard let executable = await locate() else { throw TokenError.notInstalled }
        let output: Output
        do {
            output = try await run(executable, ["auth", "token", "--hostname", "github.com"])
        } catch {
            throw TokenError.failed("Couldn't run gh: \(error.localizedDescription)")
        }
        let token = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard output.status == 0, !token.isEmpty, !token.contains(where: \.isWhitespace) else {
            throw TokenError.notLoggedIn
        }
        return token
    }

    /// Apps launched from Finder don't inherit the shell's PATH, so check the usual install
    /// locations first and fall back to asking the login shell.
    static func locate() async -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            "\(home)/.local/bin/gh",
            "\(home)/.nix-profile/bin/gh",
            "/run/current-system/sw/bin/gh",
            "/usr/bin/gh",
        ]
        if let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) {
            return URL(filePath: path)
        }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard let output = try? await run(URL(filePath: shell), ["-l", "-c", "command -v gh"], timeout: .seconds(5)),
              output.status == 0 else { return nil }
        let path = output.stdout.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return FileManager.default.isExecutableFile(atPath: path) ? URL(filePath: path) : nil
    }

    struct Output: Sendable {
        let status: Int32
        let stdout: String
    }

    private static func run(_ executable: URL, _ arguments: [String], timeout: Duration = .seconds(10)) async throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let stdout = Pipe()
        process.standardOutput = stdout
        let reader = stdout.fileHandleForReading

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                let data = (try? reader.readToEnd()) ?? Data()
                continuation.resume(returning: Output(status: process.terminationStatus, stdout: String(decoding: data, as: UTF8.self)))
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
                return
            }
            Task.detached {
                try? await Task.sleep(for: timeout)
                if process.isRunning { process.terminate() }
            }
        }
    }
}
