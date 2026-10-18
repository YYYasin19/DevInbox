import SwiftUI

/// What you've hidden: snoozed items first, dismissed review requests folded away below them.
struct SnoozedListView: View {
    let model: AppModel

    @State private var showsDismissed: Bool
    @State private var selection = ListSelection()
    @Environment(\.now) private var now

    /// Dismissed reviews start folded: they're only here to be restored now and then.
    init(model: AppModel, startsWithDismissedShown: Bool = false) {
        self.model = model
        _showsDismissed = State(initialValue: startsWithDismissedShown)
    }

    var body: some View {
        let entries = model.snoozes.visibleEntries
        let dismissed = model.dismissedReviews.listedEntries(now: now)
        VStack(spacing: 0) {
            // Says where you are and how to get back, in the slot the Inbox toolbar uses.
            HStack(spacing: 4) {
                ActionButton(.back, help: "Back to the list") {
                    model.isShowingSnoozed = false
                }
                Text(dismissed.isEmpty ? "Snoozed" : "Snoozed & dismissed")
                    .font(.callout.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, Theme.Inset.fill)
            .frame(height: 32)

            if entries.isEmpty && dismissed.isEmpty {
                EmptyStateView(icon: .moon, title: "Nothing snoozed", message: "Snoozed notifications and reviews wait here until their time comes.")
            } else {
                ListHost(entries: listEntries(entries, dismissed: dismissed), selection: selection)
            }
        }
    }

    /// Keyed by the stores' keys: the two lists share one table, so their ids must differ.
    private func listEntries(_ entries: [(key: String, entry: SnoozeEntry)], dismissed: [(key: String, review: DismissedReview)]) -> [ListEntry] {
        var list: [ListEntry] = [
            ListEntry(id: "snoozed-header", kind: .header(floats: false), height: SectionHeaderModel.height(topPadding: 0), value: entries.count) { _ in
                .sectionHeader(SectionHeaderModel(icon: .moon, title: "Snoozed", count: entries.count))
            },
        ]
        if entries.isEmpty {
            list.append(.note("snoozed-empty", NoteModel(text: "Nothing snoozed right now.")))
        }
        list += entries.map { row(key: $0.key, entry: $0.entry) }
        if !dismissed.isEmpty {
            let header = SectionHeaderModel(
                icon: .xCircle, title: "Dismissed reviews", count: dismissed.count, topPadding: 8, isExpanded: showsDismissed,
                onToggle: { showsDismissed.toggle() }
            )
            list.append(ListEntry(
                id: "dismissed-header",
                kind: .header(floats: false),
                height: SectionHeaderModel.height(topPadding: 8),
                value: [dismissed.count, showsDismissed ? 1 : 0]
            ) { _ in .sectionHeader(header) })
            if showsDismissed {
                list += dismissed.map { dismissedRow(key: $0.key, review: $0.review) }
                list.append(.note("dismissed-explanation", NoteModel(
                    text: "Dismissed reviews leave this list after 30 days and stay hidden.",
                    trailing: 0,
                    top: 8,
                    bottom: 0
                )))
            }
        }
        list.append(.space("bottom", height: 4))
        return list
    }

    private func row(key: String, entry: SnoozeEntry) -> ListEntry {
        let isReview = key.hasPrefix("review:")
        return ListEntry(id: key, kind: .row(isSelectable: false), height: RowModel.heightWithButtons, value: entry) { context in
            .row(RowModel(
                icon: Inline.icon(isReview ? .eye : .bell, size: 15).tooltip(isReview ? "Review request" : "Notification"),
                title: entry.title,
                trailing: .buttons,
                detail: [
                    .text(entry.subtitle),
                    .spacer(minLength: 8),
                    Inline.text(wakeDescription(entry)).fixedSize().tooltip("Back \(context.dateFormat.timestamp(entry.until))"),
                ],
                buttons: [
                    RowButton(.unsnooze, help: "Unsnooze — show it again now") { model.unsnooze(key: key) },
                ]
            ))
        }
    }

    private func dismissedRow(key: String, review: DismissedReview) -> ListEntry {
        ListEntry(id: key, kind: .row(isSelectable: false), height: RowModel.heightWithButtons, value: review) { context in
            .row(RowModel(
                icon: Inline.icon(.xCircle, size: 15).tooltip("Dismissed review request"),
                title: review.title,
                trailing: .buttons,
                detail: [
                    Inline.text("\(review.repository.split(separator: "/").last.map(String.init) ?? review.repository) #\(review.number)")
                        .tooltip(review.repository),
                    .spacer(minLength: 8),
                    Inline.text("Hidden while your review is requested")
                        .tooltip("Dismissed \(context.dateFormat.timestamp(review.dismissedAt)). If the request ends and you're asked again, it shows up again."),
                ],
                buttons: [
                    RowButton(.eye, help: "Show again — bring this review request back") { model.restore(dismissedReview: key) },
                    RowButton(.x, help: "Remove from this list — the review request stays dismissed") { model.unlist(dismissedReview: key) },
                ]
            ))
        }
    }

    private func wakeDescription(_ entry: SnoozeEntry) -> String {
        let time = entry.until.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        return entry.updatedAtWhenSnoozed == nil
            ? "Back \(time)"
            : "Back \(time) or on new activity"
    }
}
