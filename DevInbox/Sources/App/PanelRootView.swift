import SwiftUI

struct PanelRootView: View {
    let model: AppModel

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
        // One clock for every relative time in the panel, instead of a timer per row.
        TimelineView(.everyMinute) { context in
            Group {
                if let session = model.session {
                    MainPanelView(model: model, session: session)
                } else {
                    SignInView(model: model)
                }
            }
            .environment(\.now, context.date)
        }
        .frame(width: PanelController.size.width, height: PanelController.size.height)
        .environment(\.dateFormat, model.settings.dateFormat)
        .tooltipHost()
        .background(Theme.surface)
        .clipShape(shape)
        // A hairline rim keeps the panel's edge defined over windows of the same color.
        .overlay { shape.strokeBorder(Theme.separator, lineWidth: 1 / displayScale) }
    }
}

struct MainPanelView: View {
    @Bindable var model: AppModel
    let session: Session

    @Environment(\.now) private var now

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                if model.isShowingSnoozed {
                    SnoozedListView(model: model)
                } else {
                    switch model.selectedTab {
                    case .inbox: InboxView(model: model, session: session)
                    case .reviews: ReviewsView(model: model, session: session)
                    case .myPullRequests: MyPullRequestsView(model: model, session: session)
                    }
                }
            }
            // A new session (another login or token) starts with fresh lists, so no row keeps actions
            // bound to the old session's stores.
            .id(ObjectIdentifier(session))
            .frame(maxHeight: .infinity)
            .overlay(alignment: .bottom) { UndoToast(center: model.undo) }
            // Below the list, so rows never jump when a banner comes or goes during a refresh.
            banners
        }
    }

    // MARK: Header

    private var header: some View {
        let counts = model.menuBarState
        let isRefreshing = session.inbox.isRefreshing || session.pullRequests.isRefreshing
        return HStack(spacing: 2) {
            ForEach(Array(PanelTab.allCases.enumerated()), id: \.element) { index, tab in
                TabButton(
                    title: tab.title,
                    badge: badge(for: tab, in: counts),
                    isSelected: model.selectedTab == tab && !model.isShowingSnoozed
                ) {
                    model.isShowingSnoozed = false
                    model.selectedTab = tab
                }
                .tooltip(help(for: tab))
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
            Spacer()
            hiddenItemsButton
            ActionButton(
                .refresh,
                help: isRefreshing ? "Refreshing…" : refreshHelp,
                size: .regular,
                shortcut: KeyboardShortcut("r", modifiers: .command),
                isBusy: isRefreshing
            ) {
                session.refreshAll()
            }
            ActionButton(.settings, help: "Settings (⌘,) · signed in as @\(session.viewer.login)", size: .regular) {
                model.openSettingsAction()
            }
        }
        .padding(.leading, Theme.Inset.fill)
        .padding(.trailing, Theme.Inset.iconTrailing - 2) // 28pt buttons: glyphs end where row text ends
        .padding(.vertical, 8)
    }

    private var refreshHelp: String {
        guard let updated = session.inbox.lastUpdated else { return "Refresh (⌘R)" }
        return "Refresh (⌘R) · last updated \(RelativeTime.format(updated, relativeTo: .now))"
    }

    /// Same numbers as the menu bar, so tab badges and the status item never disagree. Only tabs with
    /// something to do get a badge; the number of your own PRs goes in the tooltip.
    private func badge(for tab: PanelTab, in counts: MenuBarState) -> TabButton.Badge? {
        switch tab {
        case .inbox: counts.unread > 0 ? .neutral(counts.unread) : nil
        // Red like the menu bar dot: only while a review request is new.
        case .reviews where counts.newReviewRequests > 0: .alert(counts.pendingReviews)
        case .reviews: counts.pendingReviews > 0 ? .neutral(counts.pendingReviews) : nil
        case .myPullRequests: nil
        }
    }

    private func help(for tab: PanelTab) -> String {
        guard tab == .myPullRequests else { return tab.help }
        let store = session.pullRequests
        let shown = store.authored.count
        let count = store.authoredTotal > shown ? "\(shown) of \(store.authoredTotal)" : "\(shown)"
        return "\(tab.help) · \(count) open"
    }

    // MARK: Banners

    @ViewBuilder
    private var banners: some View {
        let error = session.inbox.error ?? session.pullRequests.error
        let restricted = session.restrictedOrganizations
        let update = model.updater.readyVersion
        if error != nil || !restricted.isEmpty || update != nil {
            VStack(spacing: 6) {
                if let update {
                    MessageBanner(
                        icon: .refresh,
                        tone: .attention,
                        text: "DevInbox \(update) is ready.",
                        actionTitle: "Restart to Update",
                        actionHelp: "Install the update and reopen DevInbox, which takes a second",
                        action: { model.updater.installAndRelaunch(nil) }
                    )
                }
                if let error {
                    MessageBanner(
                        icon: error == .offline ? .offline : .warning,
                        tone: .warning,
                        text: error.localizedDescription
                    )
                }
                if !restricted.isEmpty {
                    MessageBanner(
                        icon: .lock,
                        tone: .attention,
                        text: "\(restricted.sorted().joined(separator: ", ")) restricts OAuth apps and hasn't approved the GitHub CLI, so some details are hidden.",
                        actionTitle: "Request access",
                        actionHelp: "Open GitHub's settings for the GitHub CLI to request access for these organizations",
                        action: {
                            NSWorkspace.shared.open(GitHubCLI.connectionsURL)
                        }
                    )
                }
            }
            .padding(.horizontal, Theme.Inset.fill)
            .padding(.vertical, 8)
        }
    }

    /// Snoozed and dismissed items, only shown while there are any. The number counts what's snoozed:
    /// dismissed reviews are folded away in that list, too.
    @ViewBuilder
    private var hiddenItemsButton: some View {
        let snoozed = model.snoozes.visibleEntries.count
        let dismissed = model.dismissedReviews.listedEntries(now: now).count
        if snoozed + dismissed > 0 || model.isShowingSnoozed {
            Button {
                model.isShowingSnoozed.toggle()
            } label: {
                HStack(spacing: 4) {
                    IconView(icon: .moon, size: 14)
                    if snoozed > 0 {
                        Text(verbatim: "\(snoozed)").monospacedDigit()
                    }
                }
            }
            .buttonStyle(PillButtonStyle(isSelected: model.isShowingSnoozed, height: Theme.Control.regularHeight))
            .font(.system(size: 12, weight: .medium))
            .focusable(false)
            .tooltip(model.isShowingSnoozed ? "Back to the list" : hiddenSummary(snoozed: snoozed, dismissed: dismissed))
        }
    }

    private func hiddenSummary(snoozed: Int, dismissed: Int) -> String {
        switch (snoozed, dismissed) {
        case (_, 0): "\(snoozed) snoozed"
        case (0, _): "\(dismissed) dismissed review \(dismissed == 1 ? "request" : "requests")"
        default: "\(snoozed) snoozed · \(dismissed) dismissed"
        }
    }
}

private struct TabButton: View {
    enum Badge {
        case neutral(Int)
        case alert(Int)
    }

    let title: String
    let badge: Badge?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        // Constant weight: switching tabs must not shift the other labels.
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                if let badge {
                    badgeView(badge)
                }
            }
        }
        .buttonStyle(PillButtonStyle(isSelected: isSelected, height: Theme.Control.regularHeight))
        .font(.system(size: 13, weight: .medium))
        .focusable(false)
    }

    private func badgeView(_ badge: Badge) -> some View {
        let (count, isAlert) = switch badge {
        case .neutral(let count): (count, false)
        case .alert(let count): (count, true)
        }
        return Text(verbatim: "\(count)")
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(isAlert ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 16)
            .background(Capsule().fill(isAlert ? Color.red : Theme.Fill.selected))
    }
}

/// An inset card for errors and hints, shown below the list.
struct MessageBanner: View {
    let icon: Icon
    let tone: Tone
    let text: String
    var actionTitle: String?
    var actionHelp: String?
    var action: (() -> Void)?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            IconView(icon: icon, size: 15)
                .foregroundStyle(tone.symbol)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2.5 }
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
                    .focusable(false)
                    .tooltip(actionHelp ?? actionTitle)
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(tone.fill, in: shape)
        .overlay(shape.strokeBorder(tone.symbol.opacity(0.25), lineWidth: 1))
    }
}
