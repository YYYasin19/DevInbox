import AppKit
import SwiftUI

/// The lists of the panel, drawn by AppKit: a table view that reuses its rows, so scrolling only
/// configures and draws the rows coming into view, where SwiftUI's lazy stacks built each one anew.
///
/// Rows are described by `ListEntry` values. Updates keep the rows that stayed and redraw only those
/// whose value changed. The highlight follows the pointer and the keyboard (see `ListSelection`).
struct ListHost: NSViewRepresentable {
    let entries: [ListEntry]
    let selection: ListSelection
    /// Changes whenever the panel is opened, so the list takes keyboard focus again.
    var focusTrigger: Int?
    /// What the keyboard does to the selected row. Nil for lists without keyboard commands.
    var perform: ((ListCommand, String) -> Void)?

    @Environment(\.now) private var now
    @Environment(\.dateFormat) private var dateFormat
    @Environment(TooltipCenter.self) private var tooltips: TooltipCenter?

    func makeNSView(context: Context) -> ListView {
        ListView(selection: selection)
    }

    func updateNSView(_ view: ListView, context: Context) {
        view.perform = perform
        view.tooltips = tooltips
        view.update(entries, now: now, dateFormat: dateFormat)
        if let focusTrigger, view.focusTrigger != focusTrigger {
            let isFirstUpdate = view.focusTrigger == nil
            view.focusTrigger = focusTrigger
            if !isFirstUpdate {
                view.takeFocus()
                selection.resetPointer()
            }
        }
    }
}

/// The highlighted row of a list. Hovering selects rows like in a menu, so R/D/S always act on the
/// row you see highlighted, and the keyboard moves the same highlight.
///
/// The pointer selects when it moves, and while you scroll with a trackpad or wheel, so the highlight
/// follows the row under it. Rows sliding under a resting pointer because the keyboard scrolled the
/// list don't steal the selection.
final class ListSelection {
    private(set) var selectedID: String?
    private(set) var isPointerDriven = false
    /// The row that just copied its branch name.
    fileprivate(set) var copiedID: String?
    /// The selectable rows in list order, for the keyboard and to move off a row that leaves the list.
    fileprivate(set) var ids: [String] = []
    fileprivate weak var view: ListView?

    #if DEBUG
    /// A resting pointer for the scroll benchmark, in the list.
    static var simulatedPointer: CGPoint?
    /// How often the highlight moved, so the benchmark can tell that the pointer did its job.
    static var changeCount = 0
    /// Rows drawn highlighted, with their buttons, for snapshots.
    var pinnedIDs: Set<String> = []
    #endif

    init() {
        ScrollActivity.startMonitoring()
    }

    func select(_ id: String?, byPointer: Bool) {
        #if DEBUG
        if id != selectedID { Self.changeCount += 1 }
        #endif
        let previous = selectedID
        selectedID = id
        isPointerDriven = byPointer
        view?.selectionChanged(from: previous, to: id)
    }

    func clear() {
        select(nil, byPointer: isPointerDriven)
    }

    /// Selects and scrolls the row into view, without animation.
    func selectWithKeyboard(_ id: String?) {
        let previous = selectedID
        select(id, byPointer: false)
        if let id { view?.scrollToKeyboardSelection(id, from: previous) }
    }

    /// Moves the selection on before the selected row leaves the list, so ↑/↓ continue from there.
    func moveOff(_ id: String) {
        guard selectedID == id else { return }
        let next = ids.neighbor(of: id)
        if isPointerDriven {
            select(next, byPointer: true)
        } else {
            selectWithKeyboard(next)
        }
    }

    /// Says the row copied its branch name: it shows its buttons, with a checkmark on the copy one, for
    /// a moment, even when selected by keyboard.
    func flashCopied(_ id: String) {
        copiedID = id
        view?.reconfigure(id)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, copiedID == id else { return }
            copiedID = nil
            view?.reconfigure(id)
        }
    }

    func scrollToTop() {
        view?.scrollToTop()
    }

    /// The panel opened: the pointer is somewhere else until it moves.
    func resetPointer() {
        view?.resetPointer()
    }

    /// Opens the snooze presets under a row selected with the keyboard, near where its button would be.
    func showSnoozeMenu(for id: String, onSelect: @escaping (SnoozeOption) -> Void) {
        view?.showSnoozeMenu(for: id, onSelect: onSelect)
    }
}

final class ListView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let selection: ListSelection
    var perform: ((ListCommand, String) -> Void)?
    weak var tooltips: TooltipCenter?
    var focusTrigger: Int?

    private let scrollView = NSScrollView()
    private let tableView = ListTableView()
    /// Shown while content is scrolled under the top edge.
    private let hairline = FillView(color: .separatorColor)
    private(set) var entries: [ListEntry] = []
    private var indexByID: [String: Int] = [:]
    private var separatorBelow: [Bool] = []
    private var context = ListContext(now: .now, dateFormat: .monthDay)
    /// In the list's coordinates, which don't move while the content scrolls. Nil while outside.
    private var pointer: NSPoint?
    private var tooltipIDs: [String: UUID] = [:]
    private var currentTooltip: UUID?
    private var trackingArea: NSTrackingArea?

    init(selection: ListSelection) {
        self.selection = selection
        super.init(frame: NSRect(origin: .zero, size: PanelController.size))
        selection.view = self

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.allowsTypeSelect = false
        tableView.focusRingType = .none
        tableView.gridStyleMask = []
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.floatsGroupRows = true
        tableView.rowSizeStyle = .custom
        tableView.usesAutomaticRowHeights = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.list = self

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(didScroll), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        addSubview(scrollView)
        hairline.isHidden = true
        addSubview(hairline)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        // Without the scroller when it takes room ("Show scroll bars: Always").
        tableView.tableColumns.first?.width = scrollView.contentSize.width
        hairline.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1 / (window?.backingScaleFactor ?? 2))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        Task { [weak self] in self?.takeFocus() }
    }

    func takeFocus() {
        window?.makeFirstResponder(tableView)
    }

    // MARK: Updates

    func update(_ newEntries: [ListEntry], now: Date, dateFormat: DateFormat) {
        let contextChanged = now != context.now || dateFormat != context.dateFormat
        context.now = now
        context.dateFormat = dateFormat
        let old = entries
        var oldHeights: [String: CGFloat] = [:]
        var oldValues: [String: AnyHashable] = [:]
        for (row, entry) in old.enumerated() {
            oldHeights[entry.id] = height(of: row)
            oldValues[entry.id] = entry.value
        }

        entries = newEntries
        indexByID = Dictionary(newEntries.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        separatorBelow = newEntries.indices.map { $0 + 1 < newEntries.count && newEntries[$0].isRow && newEntries[$0 + 1].isRow }
        selection.ids = newEntries.filter(\.isSelectable).map(\.id)

        let oldIDs = old.map(\.id)
        let newIDs = newEntries.map(\.id)
        if oldIDs != newIDs {
            let difference = newIDs.difference(from: oldIDs)
            if old.isEmpty || difference.count > 60 {
                tableView.reloadData()
                updateHairline()
                return
            }
            // Rows that stayed keep their views; new ones appear without animation, like before.
            tableView.beginUpdates()
            for case .remove(let offset, _, _) in difference.removals.reversed() {
                tableView.removeRows(at: [offset], withAnimation: [])
            }
            for case .insert(let offset, _, _) in difference.insertions {
                tableView.insertRows(at: [offset], withAnimation: [])
            }
            tableView.endUpdates()
        }

        var resized = IndexSet()
        for (row, entry) in newEntries.enumerated() {
            if let oldHeight = oldHeights[entry.id], oldHeight != height(of: row) { resized.insert(row) }
        }
        if !resized.isEmpty {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                tableView.noteHeightOfRows(withIndexesChanged: resized)
            }
        }

        tableView.enumerateAvailableRowViews { rowView, row in
            guard row < entries.count, let cell = rowView.view(atColumn: 0) as? ListCell else { return }
            let entry = entries[row]
            // New rows were just configured.
            guard let oldValue = oldValues[entry.id] else { return }
            if contextChanged || cell.entryID != entry.id || oldValue != entry.value {
                if !configure(cell, row: row) {
                    tableView.reloadData(forRowIndexes: [row], columnIndexes: [0])
                }
            } else if let cell = cell as? RowCell {
                cell.apply(state(for: row))
            }
        }
        updateHairline()
    }

    /// Redraws one row, e.g. to show that it copied something.
    func reconfigure(_ id: String) {
        guard let row = indexByID[id], let cell = cell(at: row) else { return }
        _ = configure(cell, row: row)
    }

    func selectionChanged(from old: String?, to new: String?) {
        var rows = IndexSet()
        for id in [old, new].compactMap({ $0 }) {
            guard let row = indexByID[id] else { continue }
            rows.insert(row)
            // Its separator belongs to the row above.
            if row > 0 { rows.insert(row - 1) }
        }
        for row in rows {
            (cell(at: row) as? RowCell)?.apply(state(for: row))
        }
    }

    private func height(of row: Int) -> CGFloat {
        entries[row].height + (separatorBelow[row] ? 1 : 0)
    }

    private func cell(at row: Int) -> ListCell? {
        tableView.rowView(atRow: row, makeIfNecessary: false)?.view(atColumn: 0) as? ListCell
    }

    private func listContext(for entry: ListEntry) -> ListContext {
        var context = context
        context.isCopied = entry.id == selection.copiedID
        return context
    }

    private func isHighlighted(_ id: String) -> Bool {
        #if DEBUG
        if selection.pinnedIDs.contains(id) { return true }
        #endif
        return id == selection.selectedID
    }

    private func state(for row: Int) -> RowState {
        let entry = entries[row]
        let isSelected = isHighlighted(entry.id)
        let isNextSelected = row + 1 < entries.count && isHighlighted(entries[row + 1].id)
        var showsActions = (isSelected && selection.isPointerDriven) || entry.id == selection.copiedID
        #if DEBUG
        if selection.pinnedIDs.contains(entry.id) { showsActions = true }
        #endif
        // Separators are hidden next to the highlight, so lines never cut into it.
        return RowState(isSelected: isSelected, showsActions: showsActions, showsSeparator: separatorBelow[row] && !isSelected && !isNextSelected)
    }

    /// Fills `cell` with its entry, or returns false when the entry needs another kind of cell.
    private func configure(_ cell: ListCell, row: Int) -> Bool {
        let entry = entries[row]
        switch (entry.content(listContext(for: entry)), cell) {
        case (.row(let model), let cell as RowCell):
            cell.configure(model, id: entry.id, state: state(for: row))
        case (.repositoryHeader(let model), let cell as RepositoryHeaderCell):
            cell.configure(model, id: entry.id)
        case (.sectionHeader(let model), let cell as SectionHeaderCell):
            cell.configure(model, id: entry.id)
        case (.note(let model), let cell as NoteCell):
            cell.configure(model, id: entry.id)
        case (.space, let cell as SpaceCell):
            cell.entryID = entry.id
        default:
            return false
        }
        return true
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        height(of: row)
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        entries[row].kind == .header(floats: true)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        false
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        if let rowView = tableView.makeView(withIdentifier: ListRowView.identifier, owner: nil) as? ListRowView { return rowView }
        let rowView = ListRowView()
        rowView.identifier = ListRowView.identifier
        return rowView
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = entries[row]
        let cell: ListCell = switch entry.content(listContext(for: entry)) {
        case .row: dequeue(RowCell.identifier, RowCell.init)
        case .repositoryHeader: dequeue(RepositoryHeaderCell.identifier, RepositoryHeaderCell.init)
        case .sectionHeader: dequeue(SectionHeaderCell.identifier, SectionHeaderCell.init)
        case .note: dequeue(NoteCell.identifier, NoteCell.init)
        case .space: dequeue(SpaceCell.identifier, SpaceCell.init)
        }
        _ = configure(cell, row: row)
        return cell
    }

    private func dequeue<Cell: ListCell>(_ identifier: NSUserInterfaceItemIdentifier, _ make: (NSRect) -> Cell) -> Cell {
        if let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? Cell { return cell }
        let cell = make(.zero)
        cell.identifier = identifier
        return cell
    }

    // MARK: Scrolling

    @objc private func didScroll() {
        updateHairline()
        #if DEBUG
        if let simulated = ListSelection.simulatedPointer {
            selectRow(at: simulated)
            return
        }
        #endif
        guard ScrollActivity.isScrolling, let pointer else { return }
        selectRow(at: pointer)
    }

    private func updateHairline() {
        hairline.isHidden = scrollView.contentView.bounds.minY <= 0.5
    }

    func scrollToTop() {
        scroll(to: 0)
    }

    /// Scrolls just enough to show the row. Moving up also keeps the row above it (or its section
    /// header) in view, so the selected row never ends up under a pinned header.
    func scrollToKeyboardSelection(_ id: String, from previous: String?) {
        guard let row = indexByID[id] else { return }
        let isMovingUp = previous.flatMap { indexByID[$0] }.map { $0 > row } ?? true
        var target = tableView.rect(ofRow: row)
        if isMovingUp {
            target = target.union(row > 0 ? tableView.rect(ofRow: row - 1) : NSRect(x: 0, y: 0, width: 1, height: 1))
        }
        let visible = scrollView.contentView.bounds
        var y = visible.minY
        if target.maxY > visible.maxY { y = target.maxY - visible.height }
        if target.minY < y { y = target.minY }
        if y != visible.minY { scroll(to: y) }
    }

    private func scroll(to y: CGFloat) {
        let maxY = max(tableView.frame.height - scrollView.contentView.bounds.height, 0)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(max(y, 0), maxY)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func showSnoozeMenu(for id: String, onSelect: @escaping (SnoozeOption) -> Void) {
        guard let row = indexByID[id] else { return }
        let rect = tableView.rect(ofRow: row)
        SnoozeMenu.show(below: NSRect(x: rect.maxX - 180, y: rect.minY, width: 0, height: entries[row].height), in: tableView, onSelect: onSelect)
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        pointerMoved(event)
    }

    override func mouseMoved(with event: NSEvent) {
        pointerMoved(event)
    }

    override func mouseExited(with event: NSEvent) {
        pointer = nil
        updateTooltip(at: nil, event: event)
    }

    func resetPointer() {
        pointer = nil
    }

    private func pointerMoved(_ event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard location != pointer else { return }
        pointer = location
        selectRow(at: location)
        updateTooltip(at: location, event: event)
    }

    private func selectRow(at location: NSPoint) {
        guard let row = row(at: location), entries[row].isSelectable else { return }
        let id = entries[row].id
        guard id != selection.selectedID || !selection.isPointerDriven else { return }
        selection.select(id, byPointer: true)
    }

    /// The row under `location`, from the rows' frames rather than the views, which can lag behind
    /// fast scrolling. A pinned section header covers the rows scrolling under it.
    private func row(at location: NSPoint) -> Int? {
        let point = tableView.convert(location, from: self)
        let row = tableView.row(at: point)
        guard row >= 0 else { return nil }
        if let header = pinnedHeaderFrame(), header.contains(point) { return nil }
        return row
    }

    private func pinnedHeaderFrame() -> NSRect? {
        let visible = scrollView.contentView.bounds
        let top = tableView.row(at: NSPoint(x: 1, y: visible.minY))
        guard top >= 0, let header = entries[...top].lastIndex(where: { $0.kind == .header(floats: true) }) else { return nil }
        let frame = tableView.rect(ofRow: header)
        var y = max(frame.minY, visible.minY)
        if let next = entries[(header + 1)...].firstIndex(where: { $0.kind == .header(floats: true) }) {
            y = min(y, tableView.rect(ofRow: next).minY - frame.height)
        }
        return NSRect(x: frame.minX, y: y, width: frame.width, height: frame.height)
    }

    // MARK: Tooltips

    /// Feeds the panel's tooltips (see `TooltipCenter`) from the rows' pieces and buttons.
    private func updateTooltip(at location: NSPoint?, event: NSEvent) {
        guard let tooltips else { return }
        let found = location.flatMap(tooltip(at:))
        let id = found.map { found in
            if let id = tooltipIDs[found.key] { return id }
            let id = UUID()
            tooltipIDs[found.key] = id
            return id
        }
        if let currentTooltip, currentTooltip != id {
            tooltips.pointerLeft(id: currentTooltip)
        }
        currentTooltip = id
        if let id, let found, let content = window?.contentView {
            let point = content.convert(event.locationInWindow, from: nil)
            let location = CGPoint(x: point.x, y: content.isFlipped ? point.y : content.bounds.height - point.y)
            tooltips.pointerMoved(id: id, text: found.text, at: location)
        }
    }

    private func tooltip(at location: NSPoint) -> (key: String, text: String)? {
        var view = scrollView.hitTest(location)
        while let current = view, current !== self {
            if let button = current as? IconButton {
                return button.isHidden || button.help.isEmpty ? nil : (button.tooltipKey, button.help)
            }
            if let cell = current as? ListCell {
                return cell.tooltip(at: cell.convert(location, from: self)).map { ("\(cell.entryID).\($0.key)", $0.text) }
            }
            view = current.superview
        }
        return nil
    }

    // MARK: Keyboard

    /// ↑/↓ or j/k select, ⏎ opens, R (read), D (dismiss), S (snooze) and C (copy branch) act on the
    /// selection.
    fileprivate func handleKey(_ event: NSEvent) -> Bool {
        guard let perform, !event.modifierFlags.contains(.command) else { return false }
        switch event.specialKey {
        case .downArrow?:
            move(by: 1)
            return true
        case .upArrow?:
            move(by: -1)
            return true
        case .carriageReturn?, .enter?:
            guard let id = selection.selectedID else { return false }
            perform(.open, id)
            return true
        default:
            break
        }
        let command: ListCommand
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "j":
            move(by: 1)
            return true
        case "k":
            move(by: -1)
            return true
        case "r": command = .markRead
        case "d": command = .dismiss
        case "s": command = .snooze
        case "c": command = .copyBranch
        default: return false
        }
        if let id = selection.selectedID { perform(command, id) }
        return true
    }

    private func move(by offset: Int) {
        let ids = selection.ids
        guard !ids.isEmpty else { return }
        guard let current = selection.selectedID, let index = ids.firstIndex(of: current) else {
            selection.selectWithKeyboard(offset > 0 ? ids.first : ids.last)
            return
        }
        selection.selectWithKeyboard(ids[min(max(index + offset, 0), ids.count - 1)])
    }
}

/// Takes the keys for the list and passes the rest on, like Esc to close the panel.
private final class ListTableView: NSTableView {
    weak var list: ListView?

    override func keyDown(with event: NSEvent) {
        if list?.handleKey(event) == true { return }
        super.keyDown(with: event)
    }
}

/// Draws nothing: rows draw their own highlight, and pinned headers their own background.
private final class ListRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("listRow")

    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawSeparator(in dirtyRect: NSRect) {}
}

/// When the user last scrolled with a trackpad or wheel, including momentum after the fingers lift.
enum ScrollActivity {
    private static var lastScroll: Date = .distantPast
    private static var monitor: Any?

    static var isScrolling: Bool {
        Date.now.timeIntervalSince(lastScroll) < 0.3
    }

    static func startMonitoring() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            MainActor.assumeIsolated { lastScroll = .now }
            return event
        }
    }
}
