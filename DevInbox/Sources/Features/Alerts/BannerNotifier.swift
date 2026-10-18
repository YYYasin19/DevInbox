import Foundation
import UserNotifications

/// What DevInbox last saw of a thread, to tell new notifications from ones already announced.
nonisolated struct SeenThread: Codable, Hashable, Sendable {
    var unread: Bool
    var reason: NotificationReason
}

nonisolated enum BannerPlanner {
    /// Decides which threads deserve a banner: new unread threads, threads that became unread again,
    /// and unread threads whose reason changed (a mention turning into a review request). GitHub also
    /// moves `updated_at` for activity that doesn't notify anyone, so that alone announces nothing.
    /// Closing a pull request makes its review request unread again, but there's no review to do.
    /// Without a baseline (first run, fresh sign-in) nothing is announced, so existing
    /// notifications don't flood the screen.
    static func plan(
        threads: [NotificationThread],
        details: [String: SubjectDetails] = [:],
        baseline: [String: SeenThread]?,
        reasons: Set<NotificationReason>,
        isSnoozed: (NotificationThread) -> Bool
    ) -> (announce: [NotificationThread], baseline: [String: SeenThread]) {
        let newBaseline = Dictionary(
            threads.map { ($0.id, SeenThread(unread: $0.unread, reason: $0.reason)) },
            uniquingKeysWith: { first, _ in first }
        )
        guard let baseline else { return ([], newBaseline) }
        let announce = threads.filter { thread in
            guard thread.unread, reasons.contains(thread.reason), !isSnoozed(thread) else { return false }
            if thread.reason == .reviewRequested && InboxFilter.isFinished(details[thread.id]) { return false }
            guard let seen = baseline[thread.id] else { return true }
            return !seen.unread || seen.reason != thread.reason
        }
        return (announce, newBaseline)
    }
}

final class BannerNotifier {
    nonisolated static let threadIDKey = "threadID"
    private static let maxBanners = 4

    private let file = JSONFileStore<[String: SeenThread]>(name: "banner-baseline.json")
    private var baseline: [String: SeenThread]?

    init() {
        baseline = file.load()
    }

    func requestAuthorization() {
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
    }

    func process(
        threads: [NotificationThread],
        details: [String: SubjectDetails],
        viewer: String,
        reasons: Set<NotificationReason>,
        isSnoozed: (NotificationThread) -> Bool
    ) {
        let plan = BannerPlanner.plan(threads: threads, details: details, baseline: baseline, reasons: reasons, isSnoozed: isSnoozed)
        baseline = plan.baseline
        file.save(plan.baseline)
        if !plan.announce.isEmpty {
            Log.info(.banners, "Announcing \(plan.announce.map { "\($0.id) (\($0.logName), \($0.reason.rawValue))" }.joined(separator: ", "))")
        }

        for thread in plan.announce.prefix(Self.maxBanners) {
            let content = UNMutableNotificationContent()
            let number = thread.number.map { " #\($0)" } ?? ""
            content.title = "\(thread.reason.label) · \(thread.repository.name)\(number)"
            content.body = thread.subject.title
            if let event = details[thread.id]?.latestEvent, let actor = event.actor {
                content.subtitle = "@\(actor.login) \(event.verb(viewer: viewer))"
            }
            content.threadIdentifier = thread.repository.fullName
            content.userInfo = [Self.threadIDKey: thread.id]
            post(content, id: "\(thread.id)-\(thread.updatedAt.timeIntervalSince1970)")
        }
        if plan.announce.count > Self.maxBanners {
            let content = UNMutableNotificationContent()
            content.title = "\(plan.announce.count - Self.maxBanners) more notifications"
            content.body = "Open DevInbox to see them."
            post(content, id: "summary-\(Date.now.timeIntervalSince1970)")
        }
    }

    func reset() {
        baseline = nil
        file.delete()
    }

    private func post(_ content: UNMutableNotificationContent, id: String) {
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { Log.error(.banners, "Couldn't post a banner: \(error.localizedDescription)") }
        }
    }
}
