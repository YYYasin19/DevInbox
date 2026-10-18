import AppKit

/// What the keyboard does to a list's selected row (see `ListView`).
enum ListCommand {
    case open
    case markRead
    case dismiss
    case snooze
    case copyBranch
}

extension Array where Element == String {
    /// The id to select after `id` disappears from the list.
    func neighbor(of id: String) -> String? {
        guard let index = firstIndex(of: id) else { return nil }
        if index + 1 < count { return self[index + 1] }
        return index > 0 ? self[index - 1] : nil
    }
}

/// The snooze presets as a native menu, with 1–4 as shortcuts (the button, or S then 1–4).
enum SnoozeMenu {
    /// Below `rect`, in `view`'s coordinates.
    static func show(below rect: NSRect, in view: NSView, onSelect: @escaping (SnoozeOption) -> Void) {
        let now = Date.now
        let items = SnoozeOption.allCases.enumerated().map { index, option in
            NativeMenu.Item(
                title: option.title,
                subtitle: option.date(from: now).formatted(.dateTime.weekday(.abbreviated).hour().minute()),
                keyEquivalent: "\(index + 1)"
            ) { onSelect(option) }
        }
        NativeMenu.show(items, below: rect, in: view, title: "Snooze until…")
    }
}
