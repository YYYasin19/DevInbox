import SwiftUI

struct InboxView: View {
    @Bindable var model: AppModel
    let session: Session

    @State private var selection = ListSelection()

    private var inbox: InboxStore { session.inbox }

    private struct RepositorySection: Identifiable {
        let id: String
        let repository: NotificationThread.Repository?
        let threads: [NotificationThread]
    }

    /// In the store's order: latest activity first, and still while the panel is open.
    private var visibleThreads: [NotificationThread] {
        inbox.threads.filter(passesFilters)
    }

    private func passesFilters(_ thread: NotificationThread) -> Bool {
        let settings = model.settings
        return model.isVisible(thread)
            && InboxFilter.matches(
                inbox.details[thread.id], actor: settings.actorFilter, finishedOnly: settings.finishedOnly,
                overrides: settings.actorOverrides
            )
    }

    private var sections: [RepositorySection] {
        let threads = visibleThreads
        switch model.settings.inboxGrouping {
        case .chronological:
            return [RepositorySection(id: "all", repository: nil, threads: threads)]
        case .repository:
            // Dictionary grouping keeps the per-repository order; sections sort by their first thread.
            let position = Dictionary(uniqueKeysWithValues: threads.enumerated().map { ($1.id, $0) })
            return Dictionary(grouping: threads, by: \.repository.fullName)
                .map { RepositorySection(id: $0.key, repository: $0.value.first?.repository, threads: $0.value) }
                .sorted { position[$0.threads[0].id, default: 0] < position[$1.threads[0].id, default: 0] }
        }
    }

    var body: some View {
        let sections = sections

        VStack(spacing: 0) {
            toolbar(visible: sections.filter { !isCollapsed($0) }.flatMap(\.threads))
            if sections.allSatisfy(\.threads.isEmpty) {
                emptyState
            } else {
                ListHost(entries: entries(sections), selection: selection, focusTrigger: model.panelOpenCount) { command, id in
                    perform(command, on: id)
                }
                .newItemsPill(count: inbox.heldThreads.count(where: passesFilters), noun: ("notification", "notifications")) {
                    inbox.showAll()
                    selection.scrollToTop()
                }
            }
        }
    }

    private func perform(_ command: ListCommand, on id: String) {
        guard let thread = inbox.thread(id: id) else { return }
        switch command {
        case .open:
            model.open(thread)
        case .markRead:
            selection.moveOff(id)
            model.markRead([id])
        case .dismiss:
            break // D dismisses in Reviews; here the checkmark (R) is the one way out of the list.
        case .copyBranch:
            break
        case .snooze:
            selection.showSnoozeMenu(for: id) { option in
                selection.moveOff(id)
                model.snooze(thread, option: option)
            }
        }
    }

    private func entries(_ sections: [RepositorySection]) -> [ListEntry] {
        var entries: [ListEntry] = []
        for section in sections {
            if let repository = section.repository {
                entries.append(repositoryHeader(repository, threads: section.threads))
            }
            if !isCollapsed(section) {
                entries += section.threads.map { row(for: $0, showsRepository: section.repository == nil) }
            }
        }
        entries.append(.space("bottom", height: 4))
        return entries
    }

    private func isCollapsed(_ section: RepositorySection) -> Bool {
        section.repository != nil && model.settings.collapsedRepositories.contains(section.id)
    }

    /// Collapses or expands one repository, or with ⌥ all of them, like disclosure triangles in Finder.
    private func toggleCollapsed(_ repository: String, allRepositories: Bool, sections: [RepositorySection]) {
        var collapsed = model.settings.collapsedRepositories
        let collapse = !collapsed.contains(repository)
        let affected = allRepositories ? sections.compactMap { $0.repository?.fullName } : [repository]
        if collapse {
            collapsed.formUnion(affected)
        } else {
            collapsed.subtract(affected)
        }
        model.settings.collapsedRepositories = collapsed
        if let id = selection.selectedID, let thread = inbox.thread(id: id), collapsed.contains(thread.repository.fullName) {
            selection.clear()
        }
    }

    // MARK: - Toolbar

    /// `visible` is what the filters and collapsed repositories leave; the bulk actions act on it.
    private func toolbar(visible: [NotificationThread]) -> some View {
        @Bindable var settings = model.settings
        return HStack(spacing: 6) {
            SegmentedPills(
                options: [(AppSettings.InboxGrouping.repository, "By repo"), (.chronological, "Latest")],
                selection: $settings.inboxGrouping
            )
            .fixedSize()
            .tooltip("Group notifications by repository, or show the latest activity first")

            // Filters get the accent only while they hide something.
            ActorFilterPicker(filter: $settings.actorFilter)
            FilterToggle(title: "Closed", icon: .checkCircle, isOn: $settings.finishedOnly)
                .tooltip(settings.finishedOnly
                    ? "Showing merged and closed pull requests and closed issues only. Click to show all."
                    : "Show only notifications whose pull request or issue is merged or closed")

            Spacer(minLength: 0)

            ActionButton(.read, help: "Mark all \(visible.count) visible notifications as read (⌘Z undoes it)") {
                selection.clear()
                model.markRead(visible.map(\.id))
            }
            .disabled(visible.isEmpty)
        }
        .padding(.leading, Theme.Inset.fill)
        .padding(.trailing, Theme.Inset.iconTrailing)
        .frame(height: 32)
    }

    private var emptyState: some View {
        Group {
            if inbox.lastUpdated == nil, let error = inbox.error {
                LoadFailedView(error: error, what: "notifications")
            } else if inbox.lastUpdated == nil {
                LoadingView()
            } else if !inbox.threads.isEmpty && hasFilters {
                EmptyStateView(icon: .filter, title: "Nothing matches these filters", message: "No notifications are \(activeFilterNames). Turn a filter off to see more.")
            } else {
                EmptyStateView(icon: .inbox, title: "Inbox zero", message: "Nothing here. New notifications show up automatically.")
            }
        }
    }

    private var hasFilters: Bool {
        model.settings.actorFilter != .all || model.settings.finishedOnly
    }

    private var activeFilterNames: String {
        var names: [String] = []
        switch model.settings.actorFilter {
        case .all: break
        case .people: names.append("from people")
        case .bots: names.append("from bots")
        }
        if model.settings.finishedOnly { names.append("closed") }
        return names.formatted(.list(type: .and))
    }

    // MARK: - Rows

    private func row(for thread: NotificationThread, showsRepository: Bool) -> ListEntry {
        let details = inbox.details[thread.id]
        let row = NotificationRow(
            thread: thread,
            details: details,
            viewer: session.viewer.login,
            showsRepository: showsRepository,
            isActorBot: !InboxFilter.isFromPerson(details, overrides: model.settings.actorOverrides),
            canDismissReviewRequest: thread.reason == .reviewRequested && !InboxFilter.isFinished(details)
        )
        let actions = NotificationRow.Actions(
            onOpen: {
                selection.select(thread.id, byPointer: true)
                model.open(thread)
            },
            onMarkRead: {
                selection.moveOff(thread.id)
                model.markRead([thread.id])
            },
            onSetActorBot: { login, isBot in model.settings.actorOverrides[login.lowercased()] = isBot },
            onDismissReviewRequest: {
                selection.moveOff(thread.id)
                model.dismissReviewRequest(of: thread)
            },
            onSnooze: { option in
                selection.moveOff(thread.id)
                model.snooze(thread, option: option)
            }
        )
        return ListEntry(id: thread.id, kind: .row(isSelectable: true), height: RowModel.height, value: row) { context in
            .row(row.model(in: context, actions: actions))
        }
    }

    /// What a repository header shows and acts on.
    private struct HeaderValue: Hashable {
        let repository: NotificationThread.Repository
        let threadIDs: [String]
        let newCount: Int
        let isCollapsed: Bool
    }

    private func repositoryHeader(_ repository: NotificationThread.Repository, threads: [NotificationThread]) -> ListEntry {
        let isCollapsed = model.settings.collapsedRepositories.contains(repository.fullName)
        let newCount = threads.count(where: \.unread)
        let ids = threads.map(\.id)
        let header = RepositoryHeaderModel(
            repository: repository,
            count: threads.count,
            newCount: newCount,
            isCollapsed: isCollapsed,
            onToggle: { allRepositories in
                toggleCollapsed(repository.fullName, allRepositories: allRepositories, sections: sections)
            },
            markRead: RowButton(.read, help: "Mark all \(threads.count) in \(repository.fullName) as read (⌘Z undoes it)") {
                model.markRead(ids)
            }
        )
        return ListEntry(
            id: "header:\(repository.fullName)",
            kind: .header(floats: true),
            height: RepositoryHeaderModel.height,
            value: HeaderValue(repository: repository, threadIDs: ids, newCount: newCount, isCollapsed: isCollapsed)
        ) { _ in .repositoryHeader(header) }
    }
}

/// A notification: who did what on the left, why you got it on the right.
struct NotificationRow: Hashable {
    let thread: NotificationThread
    let details: SubjectDetails?
    let viewer: String
    let showsRepository: Bool
    /// How the People/Bots filter sees the latest actor, to offer correcting it.
    var isActorBot = false
    /// Only for review-request notifications, and not once the pull request is merged or closed.
    var canDismissReviewRequest = false

    struct Actions {
        let onOpen: () -> Void
        /// The checkmark: read here and on GitHub (plus done there), and out of the list.
        let onMarkRead: () -> Void
        var onSetActorBot: (_ login: String, _ isBot: Bool) -> Void = { _, _ in }
        var onDismissReviewRequest: () -> Void = {}
        let onSnooze: (SnoozeOption) -> Void
    }

    func model(in context: ListContext, actions: Actions) -> RowModel {
        // Unread on GitHub means you haven't opened it yet: that's what the highlight shows.
        RowModel(
            isUnread: thread.unread,
            icon: SubjectIcon(type: thread.subject.type, state: details?.state).inline,
            title: thread.subject.title,
            trailing: time(in: context),
            detail: [
                // Who did what on the left, why you got it on the right.
                event(in: context).layoutPriority(1),
                contextLine,
                .spacer(minLength: 16),
                ReasonLabel(reason: thread.reason, subjectType: thread.subject.type, isFinished: InboxFilter.isFinished(details)).inline,
            ].compactMap { $0 },
            buttons: buttons(actions),
            menu: menu(actions),
            onOpen: actions.onOpen
        )
    }

    private func time(in context: ListContext) -> RowModel.Trailing {
        if let event = details?.latestEvent {
            RelativeTime.trailing(event.date, help: "Latest activity", in: context)
        } else {
            RelativeTime.trailing(thread.updatedAt, help: "Thread updated", in: context)
        }
    }

    private func event(in context: ListContext) -> Inline {
        guard let event = details?.latestEvent else {
            return .text(thread.subject.type.label)
        }
        let verb = event.verb(viewer: viewer)
        let pieces: [Inline]
        if let actor = event.actor {
            let name = actor.login == viewer ? "You" : actor.login
            // The verb is the more important half: a long login truncates first, but keeps a few
            // letters so it doesn't shrink to a misleading initial.
            pieces = [
                .avatar(actor.avatarUrl),
                Inline.text(name, color: .labelColor).frame(minWidth: min(CGFloat(name.count) * 6, 40)),
                Inline.text(verb).layoutPriority(1),
            ]
        } else {
            pieces = [.text(verb.prefix(1).uppercased() + verb.dropFirst())]
        }
        return Inline.stack(spacing: 4, pieces).tooltip(eventHelp(event, verb: verb, dateFormat: context.dateFormat))
    }

    private func eventHelp(_ event: TimelineEvent, verb: String, dateFormat: DateFormat) -> String {
        var parts = ["\(event.actor.map { "@\($0.login) " } ?? "")\(verb)"]
        if let count = details?.commentCount, count > 0 {
            parts.append(count == 1 ? "1 comment" : "\(count) comments")
        }
        parts.append(dateFormat.timestamp(event.date))
        return parts.joined(separator: " · ")
    }

    /// Repository (in the chronological list) and number: useful, but the first thing to go. The
    /// repository is dropped rather than cut to a few letters; its full name stays in the tooltip.
    /// The number always stays.
    private var contextLine: Inline? {
        guard showsRepository || thread.number != nil else { return nil }
        let pieces: [Inline]
        if let number = thread.number {
            pieces = [
                .separator,
                showsRepository ? Inline.text(thread.repository.name).droppable() : nil,
                .text("#\(number)", font: .detailDigits),
            ].compactMap { $0 }
        } else {
            // Without a number the separator goes with the repository, so it never stands alone.
            pieces = [Inline.stack(spacing: 4, [.separator, .text(thread.repository.name)]).droppable()]
        }
        return Inline.dropping(spacing: 4, pieces).tooltip(thread.repository.fullName)
    }

    /// Read and snooze always; dismiss for review requests that still wait.
    private func buttons(_ actions: Actions) -> [RowButton] {
        var buttons = [
            RowButton(.read, help: "Mark as read — takes it out of the list (R)", action: actions.onMarkRead),
            RowButton.snooze(actions.onSnooze),
        ]
        if canDismissReviewRequest {
            buttons.append(RowButton(.dismiss, help: "Dismiss review request — hide it here and in Reviews, and mark it read", action: actions.onDismissReviewRequest))
        }
        return buttons
    }

    /// The same actions with their names spelled out.
    private func menu(_ actions: Actions) -> [MenuItem] {
        var items: [MenuItem] = [
            .action("Open in Browser", actions.onOpen),
            .action("Mark as Read", actions.onMarkRead),
            .snooze(actions.onSnooze),
        ]
        if canDismissReviewRequest {
            items += [.separator, .action("Dismiss Review Request", actions.onDismissReviewRequest)]
        }
        if let actor = details?.latestEvent?.actor, actor.login != viewer {
            items += [
                .separator,
                .action(isActorBot ? "Treat \(actor.login) as a Person" : "Treat \(actor.login) as a Bot") {
                    actions.onSetActorBot(actor.login, !isActorBot)
                },
            ]
        }
        return items
    }
}

/// Why a notification arrived. Reasons that need you get a colored chip; the rest stay quiet text,
/// so color always means "you're needed".
struct ReasonLabel {
    let reason: NotificationReason
    let subjectType: SubjectType
    /// Merged or closed: a review request there doesn't need you anymore.
    var isFinished = false

    var inline: Inline {
        let item: Inline = style.map { Inline.chip(label, icon: $0.icon, tone: $0.tone) } ?? .text(label)
        return item
            .fixedSize()
            .tooltip("Why you got this: \(reason.explanation)" + (isRequestOver ? " It's merged or closed now, so nothing is waiting for you." : ""))
    }

    private var isRequestOver: Bool {
        reason == .reviewRequested && isFinished
    }

    private var style: (icon: Icon, tone: Tone)? {
        if isRequestOver { return nil }
        return switch reason {
        case .reviewRequested: (.eyeFill, .warning)
        case .mention: (.mention, .attention)
        case .teamMention: (.team, .attention)
        case .assign: (.assigned, .attention)
        case .securityAlert: (.security, .failure)
        default: nil
        }
    }

    /// Phrased as your relationship to the thread, never as an event, so it can't be mistaken
    /// for what happened last.
    private var label: String {
        switch reason {
        case .author:
            switch subjectType {
            case .pullRequest: "Your PR"
            case .issue: "Your issue"
            case .discussion: "Your discussion"
            default: "Yours"
            }
        case .comment, .stateChange: "Participating"
        case .manual: "Subscribed"
        default: reason.label
        }
    }
}

/// An on/off filter pill in the Inbox toolbar.
private struct FilterToggle: View {
    let title: String
    let icon: Icon
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 5) {
                IconView(icon: icon, size: 13)
                Text(title)
            }
        }
        .buttonStyle(PillButtonStyle(isSelected: isOn, selectedForeground: .accentColor, selectedFill: Color.accentColor.opacity(0.14)))
        .font(.system(size: 12, weight: .medium))
        .focusable(false)
        .fixedSize()
    }
}

/// All, people or bots: a pill that opens a native menu, which is instant and works with the keyboard.
private struct ActorFilterPicker: View {
    @Binding var filter: ActorFilter

    @State private var frame: CGRect = .zero

    var body: some View {
        Button {
            showMenu()
        } label: {
            HStack(spacing: 5) {
                IconView(icon: icon(for: filter), size: 13)
                Text(filter.label)
                IconView(icon: .chevronDown, size: 9)
            }
        }
        .buttonStyle(PillButtonStyle(
            isSelected: filter != .all,
            selectedForeground: .accentColor,
            selectedFill: Color.accentColor.opacity(0.14)
        ))
        .font(.system(size: 12, weight: .medium))
        .focusable(false)
        .fixedSize()
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        .tooltip("Show notifications from people and bots, only from people, or only from bots")
    }

    private func showMenu() {
        let items = ActorFilter.allCases.map { option in
            NativeMenu.Item(
                title: option.label,
                subtitle: option.explanation,
                image: NSImage.icon(icon(for: option), size: 15),
                isChecked: option == filter
            ) { filter = option }
        }
        NativeMenu.show(items, below: frame)
    }

    private func icon(for filter: ActorFilter) -> Icon {
        switch filter {
        case .all: .team
        case .people: .person
        case .bots: .bot
        }
    }
}
