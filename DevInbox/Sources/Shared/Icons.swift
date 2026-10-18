import SwiftUI

/// Tabler icons (outline, plus filled where a solid shape reads better at small sizes), bundled as
/// template vectors in `Assets.xcassets/Icons`. Assets are named after their role, so swapping the
/// icon set only replaces the files. The license ships in `Resources/Licenses`.
enum Icon: String {
    // Inbox and subjects
    case inbox
    case pullRequest = "pull-request"
    case pullRequestClosed = "pull-request-closed"
    case pullRequestDraft = "pull-request-draft"
    case merged
    case issueOpen = "issue-open"
    case checkCircle = "check-circle"
    case notPlanned = "not-planned"
    case tag
    case discussion
    case commit
    case workflowRun = "workflow-run"
    case security
    case bell

    // Actions
    case check
    case checks
    case moon
    case x
    case xCircle = "x-circle"
    case openInBrowser = "open-in-browser"
    case refresh
    case settings
    case filter
    case back
    case chevronRight = "chevron-right"
    case chevronDown = "chevron-down"
    case unsnooze
    case copy

    // Reasons
    case eye
    case eyeFill = "eye-fill"
    case mention
    case team
    case assigned
    case person
    case bot

    // Pull request status
    case checksPassed = "checks-passed"
    case checksFailing = "checks-failing"
    case clock
    case warning
    case changesRequested = "changes-requested"
    case approved
    case needsReviewer = "needs-reviewer"
    case unresolved
    case behind
    case lock
    case stack
    case comments
    case offline

    /// Mark as read: the one checkmark that takes a notification out of the list.
    static let read = Icon.check
    static let snooze = Icon.moon
    static let dismiss = Icon.x
}

struct IconView: View {
    let icon: Icon
    var size: CGFloat = 14

    var body: some View {
        Image(icon.rawValue)
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

extension NSImage {
    /// A template image of the icon, for AppKit (the status item).
    static func icon(_ icon: Icon, size: CGFloat) -> NSImage? {
        guard let image = NSImage(named: icon.rawValue)?.copy() as? NSImage else { return nil }
        image.size = NSSize(width: size, height: size)
        image.isTemplate = true
        return image
    }
}
