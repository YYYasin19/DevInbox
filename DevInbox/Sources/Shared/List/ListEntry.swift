import AppKit

/// One line of a `ListView`: a row, a section header, a note or blank space. The list compares
/// `value` to redraw only what changed, and builds the content when the entry scrolls into view.
struct ListEntry {
    enum Kind: Equatable {
        /// Selectable rows take the highlight and follow the pointer and the keyboard.
        case row(isSelectable: Bool)
        /// A section header; floating ones stay at the top while their rows scroll under them.
        case header(floats: Bool)
        case other
    }

    let id: String
    let kind: Kind
    /// Without the separator the list adds between two rows.
    let height: CGFloat
    /// What the entry shows, compared to tell which entries to redraw.
    let value: AnyHashable
    let content: (ListContext) -> ListContent

    var isRow: Bool {
        if case .row = kind { true } else { false }
    }

    var isSelectable: Bool {
        kind == .row(isSelectable: true)
    }

    static func space(_ id: String, height: CGFloat) -> ListEntry {
        ListEntry(id: id, kind: .other, height: height, value: height) { _ in .space }
    }

    /// Quiet text between sections, like "No reviews waiting."
    static func note(_ id: String, _ note: NoteModel) -> ListEntry {
        ListEntry(id: id, kind: .other, height: note.height, value: note.text) { _ in .note(note) }
    }
}

/// What an entry draws, built when it comes into view.
enum ListContent {
    case row(RowModel)
    case repositoryHeader(RepositoryHeaderModel)
    case sectionHeader(SectionHeaderModel)
    case note(NoteModel)
    case space
}

/// What every entry's content may depend on besides its own data.
struct ListContext {
    var now: Date
    var dateFormat: DateFormat
    /// The row just copied its branch name: its copy button shows a checkmark for a moment.
    var isCopied = false
}

/// The two-line row shared by all lists: unread marker and icon in the gutter, the title with the time
/// on the right, and a detail line underneath.
struct RowModel {
    enum Trailing {
        /// The time, swapped for the row's buttons while the pointer selects it.
        case time(String, help: String)
        /// The buttons, always shown and sitting on the title's baseline (snoozed and dismissed items).
        case buttons
    }

    static let height: CGFloat = 50
    static let heightWithButtons: CGFloat = 58

    var isUnread = false
    /// Centered in the icon column, on the middle of the title line.
    var icon: Inline
    var title: String
    var trailing: Trailing
    /// Laid out like an `HStack(spacing: 4)` in secondary 11pt text.
    var detail: [Inline]
    var buttons: [RowButton] = []
    var menu: [MenuItem] = []
    var onOpen: (() -> Void)?
}

/// An icon button at the end of a row or header.
struct RowButton {
    let icon: Icon
    let help: String
    /// Gets the button, to show a menu below it.
    let action: (NSView) -> Void

    init(_ icon: Icon, help: String, action: @escaping (NSView) -> Void) {
        self.icon = icon
        self.help = help
        self.action = action
    }

    init(_ icon: Icon, help: String, action: @escaping () -> Void) {
        self.init(icon, help: help) { _ in action() }
    }

    /// Opens the snooze presets below the button.
    static func snooze(_ onSelect: @escaping (SnoozeOption) -> Void) -> RowButton {
        RowButton(.snooze, help: "Snooze… (S)") { view in
            SnoozeMenu.show(below: view.bounds, in: view, onSelect: onSelect)
        }
    }
}

/// A context menu item.
enum MenuItem {
    case action(String, () -> Void)
    case submenu(String, [MenuItem])
    case separator

    static func snooze(_ onSelect: @escaping (SnoozeOption) -> Void) -> MenuItem {
        .submenu("Snooze", SnoozeOption.allCases.map { option in .action(option.title) { onSelect(option) } })
    }

    static func menu(_ items: [MenuItem]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            switch item {
            case .action(let title, let action):
                let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
                let target = MenuAction(action)
                item.target = target
                // The menu item holds its target only weakly.
                item.representedObject = target
                menu.addItem(item)
            case .submenu(let title, let items):
                let submenu = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                submenu.submenu = Self.menu(items)
                menu.addItem(submenu)
            case .separator:
                menu.addItem(.separator())
            }
        }
        return menu
    }
}

private final class MenuAction: NSObject {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc func run() {
        action()
    }
}

/// "owner / name" above the rows of a repository in the grouped Inbox.
struct RepositoryHeaderModel {
    static let height: CGFloat = 36

    let repository: NotificationThread.Repository
    let count: Int
    let newCount: Int
    let isCollapsed: Bool
    /// Called with true when ⌥ is held, to collapse or expand every repository.
    let onToggle: (_ allRepositories: Bool) -> Void
    let markRead: RowButton
}

/// "Snoozed 2" or "› History 26": names a section of a list, and folds it when it can.
struct SectionHeaderModel {
    static func height(topPadding: CGFloat) -> CGFloat {
        topPadding + 29
    }

    let icon: Icon
    let title: String
    let count: Int
    var topPadding: CGFloat = 0
    /// Nil for a section that can't be folded.
    var isExpanded: Bool?
    var onToggle: (() -> Void)?
}

/// Quiet text, wrapped to the row text's width.
struct NoteModel {
    var text: String
    var font: NSFont = .detail
    var color: NSColor = .tertiaryLabelColor
    var leading: CGFloat = Theme.Row.textColumn
    var trailing: CGFloat = Theme.Inset.content
    var top: CGFloat = 6
    var bottom: CGFloat = 6

    var attributedText: NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    }

    var height: CGFloat {
        let width = PanelController.size.width - leading - trailing
        let bounds = attributedText.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin])
        return top + ceil(bounds.height) + bottom
    }
}
