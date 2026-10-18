import AppKit
import Network

/// Everything that exists while signed in: API client, stores and the polling loops.
@Observable
final class Session {
    let viewer: Viewer
    let inbox: InboxStore
    let pullRequests: PullRequestsStore

    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var wasOffline = false

    private static let pullRequestInterval: Duration = .seconds(180)

    init(client: GitHubClient, viewer: Viewer) {
        self.viewer = viewer
        inbox = InboxStore(client: client, viewer: viewer.login)
        pullRequests = PullRequestsStore(client: client, viewer: viewer.login)
    }

    var restrictedOrganizations: Set<String> {
        inbox.restrictedOrganizations.union(pullRequests.restrictedOrganizations)
    }

    func start() {
        tasks = [
            Task { [inbox] in
                while !Task.isCancelled {
                    await inbox.refresh()
                    try? await Task.sleep(for: inbox.pollInterval)
                }
            },
            Task { [pullRequests] in
                while !Task.isCancelled {
                    await pullRequests.refresh()
                    try? await Task.sleep(for: Self.pullRequestInterval)
                }
            },
        ]

        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                Log.info(.app, "Woke from sleep, refreshing")
                self?.refreshAll()
            }
        })

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let isOnline = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                if isOnline && self.wasOffline {
                    Log.info(.app, "Back online, refreshing")
                    self.refreshAll()
                } else if !isOnline && !self.wasOffline {
                    Log.info(.app, "Offline")
                }
                self.wasOffline = !isOnline
            }
        }
        pathMonitor.start(queue: .main)
    }

    func stop() {
        tasks.forEach { $0.cancel() }
        tasks = []
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        pathMonitor.cancel()
    }

    /// Manual refresh, wake and reconnect: skip `If-Modified-Since`, because reading notifications
    /// elsewhere doesn't change `Last-Modified` and would keep answering 304. Shows everything found,
    /// even while the panel is open.
    func refreshAll() {
        Task { await inbox.refresh(force: true) }
        Task { await pullRequests.refresh(showingAll: true) }
    }

    /// While the panel is open, lists hold still: refreshes update rows in place and hold new ones back.
    /// Turning it on or off shows everything that arrived.
    func holdOrder(_ holds: Bool) {
        inbox.holdsOrder = holds
        pullRequests.holdsOrder = holds
    }

    /// Called when the panel opens: refresh what's older than a short threshold.
    func refreshIfStale() {
        if inbox.lastUpdated.map({ Date.now.timeIntervalSince($0) > 15 }) ?? true {
            Task { await inbox.refresh() }
        }
        if pullRequests.lastUpdated.map({ Date.now.timeIntervalSince($0) > 60 }) ?? true {
            Task { await pullRequests.refresh() }
        }
    }
}
