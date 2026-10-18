import SwiftUI

struct ReviewsView: View {
    let model: AppModel
    let session: Session

    @State private var selection = ListSelection()

    private var store: PullRequestsStore { session.pullRequests }

    var body: some View {
        let settings = model.settings
        let pullRequests = store.reviewRequests.filter(model.isVisible(review:))
        let waitingIDs = Set(pullRequests.map(\.id))
        // A dismissed review you just brought back is up there before the next refresh takes it out of here.
        let history = store.history.filter { !waitingIDs.contains($0.id) }
        let showsHistory = settings.showsReviewHistory

        var entries = pullRequests.map(reviewEntry)
        if !history.isEmpty {
            entries += Self.historyEntries(
                history, isAloneInList: pullRequests.isEmpty, isExpanded: showsHistory,
                onToggle: { settings.showsReviewHistory.toggle() },
                onOpen: { pullRequest in
                    selection.select(pullRequest.id, byPointer: true)
                    open(pullRequest)
                }
            )
        }

        return PullRequestList(
            entries: entries,
            isLoading: store.lastUpdated == nil && store.error == nil,
            loadError: store.lastUpdated == nil ? store.error : nil,
            newCount: store.heldReviewRequests.count(where: model.isVisible(review:)) + (showsHistory ? store.heldHistory.count : 0),
            onShowNew: store.showAll,
            selection: selection,
            focusTrigger: model.panelOpenCount,
            empty: EmptyStateView(icon: .eye, title: "No reviews waiting", message: "Pull requests that ask for your review show up here.")
        ) { command, id in
            guard let pullRequest = pullRequests.first(where: { $0.id == id }) else {
                if case .open = command, let reviewed = history.first(where: { $0.id == id }) { open(reviewed) }
                return
            }
            switch command {
            case .open: open(pullRequest)
            case .snooze:
                selection.showSnoozeMenu(for: id) { option in
                    selection.moveOff(id)
                    model.snooze(review: pullRequest, option: option)
                }
            case .dismiss: dismiss(pullRequest)
            case .copyBranch: copyBranch(of: pullRequest, selection: selection)
            case .markRead: break
            }
        }
        // Unfolding the history, or opening the panel with it unfolded, catches it up.
        .task(id: showsHistory ? model.panelOpenCount : nil) {
            if showsHistory { store.refreshHistoryIfStale() }
        }
    }

    private func reviewEntry(_ pullRequest: PullRequestSummary) -> ListEntry {
        let row = ReviewRow(pullRequest: pullRequest, stack: store.stacks[pullRequest.id], viewer: session.viewer.login)
        let actions = ReviewRow.Actions(
            onOpen: {
                selection.select(pullRequest.id, byPointer: true)
                open(pullRequest)
            },
            onSnooze: { option in
                selection.moveOff(pullRequest.id)
                model.snooze(review: pullRequest, option: option)
            },
            onDismiss: { dismiss(pullRequest) },
            onCopyBranch: { copyBranch(of: pullRequest, selection: selection) }
        )
        return ListEntry(id: pullRequest.id, kind: .row(isSelectable: true), height: RowModel.height, value: row) { context in
            .row(row.model(in: context, actions: actions))
        }
    }

    /// "History" below the waiting reviews: pull requests you reviewed or were asked to review, and what
    /// happened to them since. Folded until you open it, and it stays the way you left it.
    static func historyEntries(
        _ history: [ReviewedPullRequest],
        isAloneInList: Bool,
        isExpanded: Bool,
        onToggle: @escaping () -> Void,
        onOpen: @escaping (ReviewedPullRequest) -> Void
    ) -> [ListEntry] {
        var entries: [ListEntry] = []
        if isAloneInList {
            entries.append(.note("history-alone", NoteModel(text: "No reviews waiting.")))
        }
        let topPadding: CGFloat = isAloneInList ? 0 : 8
        let header = SectionHeaderModel(
            icon: .clock, title: "History", count: history.count, topPadding: topPadding, isExpanded: isExpanded, onToggle: onToggle
        )
        entries.append(ListEntry(
            id: "history-header",
            kind: .header(floats: false),
            height: SectionHeaderModel.height(topPadding: topPadding),
            value: [history.count, Int(topPadding), isExpanded ? 1 : 0]
        ) { _ in .sectionHeader(header) })
        guard isExpanded else { return entries }
        for pullRequest in history {
            let row = ReviewHistoryRow(pullRequest: pullRequest)
            entries.append(ListEntry(id: pullRequest.id, kind: .row(isSelectable: true), height: RowModel.height, value: row) { context in
                .row(row.model(in: context) { onOpen(pullRequest) })
            })
        }
        entries.append(.note("history-explanation", NoteModel(
            text: "Pull requests you reviewed or were asked to review, with activity in the last 30 days.",
            top: 8,
            bottom: 0
        )))
        return entries
    }

    private func dismiss(_ pullRequest: PullRequestSummary) {
        selection.moveOff(pullRequest.id)
        model.dismiss(review: pullRequest)
    }

    /// Opening a review also marks its review-request notification as opened, like visiting the PR on github.com does.
    private func open(_ pullRequest: PullRequestSummary) {
        NSWorkspace.shared.open(pullRequest.url)
        let related = session.inbox.threads(for: pullRequest).filter(\.unread).map(\.id)
        Task { await session.inbox.markOpened(related) }
    }

    /// The same for a pull request in the history, whose notification may say it was merged.
    private func open(_ pullRequest: ReviewedPullRequest) {
        NSWorkspace.shared.open(pullRequest.url)
        let related = session.inbox.threads(repository: pullRequest.repository, number: pullRequest.number).filter(\.unread).map(\.id)
        Task { await session.inbox.markOpened(related) }
    }
}

struct MyPullRequestsView: View {
    let model: AppModel
    let session: Session

    @State private var selection = ListSelection()

    private var store: PullRequestsStore { session.pullRequests }

    var body: some View {
        let botOverrides = model.settings.actorOverrides
        let entries = store.authored.map { pullRequest in
            let row = MyPullRequestRow(pullRequest: pullRequest, stack: store.stacks[pullRequest.id], botOverrides: botOverrides)
            let actions = MyPullRequestRow.Actions(
                onOpen: {
                    selection.select(pullRequest.id, byPointer: true)
                    NSWorkspace.shared.open(pullRequest.url)
                },
                onCopyBranch: { copyBranch(of: pullRequest, selection: selection) }
            )
            return ListEntry(id: pullRequest.id, kind: .row(isSelectable: true), height: RowModel.height, value: row) { context in
                .row(row.model(in: context, actions: actions))
            }
        }
        PullRequestList(
            entries: entries,
            isLoading: store.lastUpdated == nil && store.error == nil,
            loadError: store.lastUpdated == nil ? store.error : nil,
            newCount: store.heldAuthored.count,
            onShowNew: store.showAll,
            selection: selection,
            focusTrigger: model.panelOpenCount,
            empty: EmptyStateView(icon: .pullRequest, title: "No open pull requests", message: "Pull requests you open show up here with their CI, review and merge status.")
        ) { command, id in
            guard let pullRequest = store.authored.first(where: { $0.id == id }) else { return }
            switch command {
            case .open: NSWorkspace.shared.open(pullRequest.url)
            case .copyBranch: copyBranch(of: pullRequest, selection: selection)
            case .markRead, .dismiss, .snooze: break
            }
        }
    }
}

private struct PullRequestList<Empty: View>: View {
    /// Without the padding above and below.
    let entries: [ListEntry]
    let isLoading: Bool
    /// Set when the first load failed, so the list doesn't claim there's nothing to do.
    var loadError: GitHubError?
    /// Pull requests that arrived while the panel was open.
    let newCount: Int
    let onShowNew: () -> Void
    let selection: ListSelection
    let focusTrigger: Int
    let empty: Empty
    let perform: (ListCommand, String) -> Void

    var body: some View {
        if entries.isEmpty {
            if let loadError {
                LoadFailedView(error: loadError, what: "pull requests")
            } else if isLoading {
                LoadingView()
            } else {
                empty
            }
        } else {
            ListHost(
                entries: [.space("top", height: 4)] + entries + [.space("bottom", height: 4)],
                selection: selection,
                focusTrigger: focusTrigger,
                perform: perform
            )
            .newItemsPill(count: newCount, noun: ("pull request", "pull requests")) {
                onShowNew()
                selection.scrollToTop()
            }
        }
    }
}

/// "wohngeld #6949 · Draft · 2/3": where the pull request lives. Quiet, and the first to truncate.
private func pullRequestContext(_ pullRequest: PullRequestSummary, stack: StackInfo?, team: String? = nil) -> Inline {
    let separator = Inline.separator.fixedSize()
    var pieces: [Inline] = [
        Inline.text(pullRequest.repository.split(separator: "/").last.map(String.init) ?? pullRequest.repository)
            .tooltip(pullRequest.repository),
        // Same tooltip, so the repository stays findable when its name has no room left.
        Inline.text("#\(pullRequest.number)", font: .detailDigits).fixedSize().tooltip(pullRequest.repository),
    ]
    if pullRequest.isDraft {
        pieces += [separator, Inline.text("Draft").fixedSize().tooltip("Draft pull request — not ready for review yet.")]
    }
    if let team {
        pieces += [
            separator,
            Inline.stack(spacing: 3, [.icon(.team, size: 12), .text("via \(team)")])
                .tooltip("Your review was requested through the \(team) team."),
        ]
    }
    if let stack {
        pieces += [separator, StackLabel(stack: stack, number: pullRequest.number).inline]
    }
    return .stack(spacing: 4, pieces)
}

struct ReviewRow: Hashable {
    let pullRequest: PullRequestSummary
    let stack: StackInfo?
    let viewer: String

    struct Actions {
        let onOpen: () -> Void
        let onSnooze: (SnoozeOption) -> Void
        let onDismiss: () -> Void
        let onCopyBranch: () -> Void
    }

    func model(in context: ListContext, actions: Actions) -> RowModel {
        let requestedAt = pullRequest.reviewRequestedAt(viewer: viewer)
        let author = pullRequest.author?.login ?? "ghost"
        var status = [DiffSizeLabel.inline(additions: pullRequest.additions, deletions: pullRequest.deletions)]
        if let checks = PullRequestStatus.checks(pullRequest.checks) {
            status.append(checks.inline)
        }
        return RowModel(
            icon: SubjectIcon(type: .pullRequest, state: pullRequest.isDraft ? .draft : .open).inline,
            title: pullRequest.title,
            trailing: RelativeTime.trailing(requestedAt ?? pullRequest.updatedAt, help: requestedAt == nil ? "Last updated" : "Review requested", in: context),
            detail: [
                Inline.stack(spacing: 4, [.avatar(pullRequest.author?.avatarUrl), .text(author, color: .labelColor)])
                    .layoutPriority(1)
                    .tooltip("Opened by @\(author)"),
                .separator,
                pullRequestContext(pullRequest, stack: stack, team: pullRequest.requestingTeam(viewer: viewer)),
                .spacer(minLength: 16),
                Inline.stack(spacing: 8, status).layoutPriority(2),
            ],
            buttons: [
                copyBranchButton(pullRequest, isCopied: context.isCopied, action: actions.onCopyBranch),
                .snooze(actions.onSnooze),
                RowButton(.dismiss, help: "Dismiss review request — stop showing it and mark its notification read (D)", action: actions.onDismiss),
            ],
            menu: [
                .action("Open in Browser", actions.onOpen),
                .snooze(actions.onSnooze),
                .action("Copy Link") { copyToPasteboard(pullRequest.url.absoluteString) },
                .action("Copy Branch Name", actions.onCopyBranch),
                .separator,
                .action("Dismiss Review Request", actions.onDismiss),
            ],
            onOpen: actions.onOpen
        )
    }
}

struct MyPullRequestRow: Hashable {
    let pullRequest: PullRequestSummary
    let stack: StackInfo?
    /// The Inbox's bot corrections, so bots' comments aren't counted.
    var botOverrides: [String: Bool] = [:]

    struct Actions {
        let onOpen: () -> Void
        let onCopyBranch: () -> Void
    }

    func model(in context: ListContext, actions: Actions) -> RowModel {
        RowModel(
            icon: SubjectIcon(type: .pullRequest, state: pullRequest.isDraft ? .draft : .open).inline,
            title: pullRequest.title,
            trailing: RelativeTime.trailing(pullRequest.updatedAt, help: "Last updated", in: context),
            detail: [
                pullRequestContext(pullRequest, stack: stack),
                .spacer(minLength: 16),
                StatusLine.inline(PullRequestStatus.items(for: pullRequest, overrides: botOverrides, dateFormat: context.dateFormat))
                    .layoutPriority(2),
            ],
            buttons: [copyBranchButton(pullRequest, isCopied: context.isCopied, action: actions.onCopyBranch)],
            menu: [
                .action("Open in Browser", actions.onOpen),
                .action("Copy Link") { copyToPasteboard(pullRequest.url.absoluteString) },
                .action("Copy Branch Name", actions.onCopyBranch),
            ],
            onOpen: actions.onOpen
        )
    }
}

/// A pull request you reviewed: your part on the left, what happened since on the right.
struct ReviewHistoryRow: Hashable {
    let pullRequest: ReviewedPullRequest

    func model(in context: ListContext, onOpen: @escaping () -> Void) -> RowModel {
        let author = pullRequest.author?.login ?? "ghost"
        return RowModel(
            icon: SubjectIcon(type: .pullRequest, state: pullRequest.state).inline,
            title: pullRequest.title,
            trailing: RelativeTime.trailing(pullRequest.lastActivity, help: ReviewHistoryStatus.timeHelp(for: pullRequest), in: context),
            detail: [
                Inline.stack(spacing: 4, [
                    .avatar(pullRequest.author?.avatarUrl),
                    // Keeps a few letters, so it doesn't shrink to a misleading initial.
                    Inline.text(author, color: .labelColor).frame(minWidth: min(CGFloat(author.count) * 6, 40)),
                ])
                .tooltip("Opened by @\(author)"),
                // What happened since needs the room: the repository goes first, whole.
                Inline.dropping(spacing: 4, [
                    .separator,
                    Inline.text(pullRequest.repository.split(separator: "/").last.map(String.init) ?? pullRequest.repository).droppable(),
                    .text("#\(pullRequest.number)", font: .detailDigits),
                ])
                .tooltip(pullRequest.repository),
                // Fixed, so the stack reserves its width: a dot that measures as nothing pushed the
                // status line past the edge.
                Inline.separator.fixedSize(),
                ReviewHistoryStatus.involvement(of: pullRequest, dateFormat: context.dateFormat).inline,
                .spacer(minLength: 16),
                StatusLine.inline(ReviewHistoryStatus.items(for: pullRequest, dateFormat: context.dateFormat)).layoutPriority(2),
            ],
            menu: [
                .action("Open in Browser", onOpen),
                .action("Copy Link") { copyToPasteboard(pullRequest.url.absoluteString) },
            ],
            onOpen: onOpen
        )
    }
}

/// Copies the head branch, to check it out in the IDE (button, C or the context menu). The row shows
/// a checkmark on its copy button for a moment to say it worked, even when selected by keyboard.
private func copyBranch(of pullRequest: PullRequestSummary, selection: ListSelection) {
    copyToPasteboard(pullRequest.headRefName)
    selection.flashCopied(pullRequest.id)
}

private func copyBranchButton(_ pullRequest: PullRequestSummary, isCopied: Bool, action: @escaping () -> Void) -> RowButton {
    let fork = pullRequest.isCrossRepository ? " (in a fork)" : ""
    return RowButton(isCopied ? .check : .copy, help: "Copy branch name: \(pullRequest.headRefName)\(fork) (C)", action: action)
}

private func copyToPasteboard(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
}
