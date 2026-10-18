import AppKit
import Testing
@testable import DevInbox

/// Lines are laid out like the SwiftUI stacks they replaced; these rules were measured there.
struct InlineLayoutTests {
    private let long = "customer-feedback-from-enterprise-onboarding-and-self-serve"

    private func widths(_ items: [Inline], spacing: CGFloat = 0, in width: CGFloat) -> [CGFloat] {
        var layout = InlineLayout()
        layout.place(.stack(spacing: spacing, items), x: 0, width: width, centerY: 0, key: "")
        return layout.pieces.map(\.frame.width)
    }

    @Test func spacersOnlyKeepTheirMinimumFromText() {
        // The text takes all but the spacer's 16pt and the fixed label, rather than half.
        let pieces = widths([.text(long), .spacer(minLength: 16), Inline.icon(.check, size: 40)], spacing: 4, in: 200)
        #expect(pieces[0] > 200 - 4 - 16 - 4 - 40 - 8)
        #expect(pieces[0] <= 200 - 4 - 16 - 4 - 40)
    }

    @Test func textsShareTheWidth() {
        let pieces = widths([.text(long), .text(long)], in: 200)
        #expect(abs(pieces[0] - pieces[1]) < 8)
        #expect(pieces[0] + pieces[1] <= 200)
    }

    @Test func higherPriorityGoesFirst() {
        let pieces = widths([.text(long), Inline.text(long).layoutPriority(1)], in: 200)
        #expect(pieces[0] < 10)
        #expect(pieces[1] > 190)
    }
}

/// Drives a list with fake rows and synthetic events, since clicking real rows reaches GitHub.
struct ListViewTests {
    private final class Log {
        var events: [String] = []
    }

    private func row(_ id: String, log: Log) -> ListEntry {
        ListEntry(id: id, kind: .row(isSelectable: true), height: RowModel.height, value: id) { _ in
            .row(RowModel(
                icon: .icon(.bell, size: 17),
                title: "Title \(id)",
                trailing: .time("1h", help: ""),
                detail: [.text("detail \(id)"), .spacer(minLength: 16), .text("reason")],
                buttons: [RowButton(.read, help: "Read") { log.events.append("button \(id)") }],
                menu: [.action("Open", { log.events.append("menu \(id)") })],
                onOpen: { log.events.append("open \(id)") }
            ))
        }
    }

    private func header(_ id: String, log: Log) -> ListEntry {
        let model = RepositoryHeaderModel(
            repository: .init(fullName: "acme/\(id)", htmlURL: URL(string: "https://github.com/acme/\(id)")!, owner: .init(login: "acme", avatarURL: nil)),
            count: 2, newCount: 1, isCollapsed: false,
            onToggle: { all in log.events.append("toggle \(id)\(all ? " all" : "")") },
            markRead: RowButton(.read, help: "Mark all read") { log.events.append("mark all \(id)") }
        )
        return ListEntry(id: "header:\(id)", kind: .header(floats: true), height: RepositoryHeaderModel.height, value: id) { _ in .repositoryHeader(model) }
    }

    private func makeList(_ entries: [ListEntry], log: Log, in window: NSWindow) -> (ListView, ListSelection) {
        let selection = ListSelection()
        let list = ListView(selection: selection)
        list.perform = { command, id in log.events.append("\(command) \(id)") }
        window.contentView = list
        window.orderFrontRegardless()
        list.update(entries, now: .now, dateFormat: .monthDay)
        list.layoutSubtreeIfNeeded()
        list.displayIfNeeded()
        return (list, selection)
    }

    /// `point` from the top left, like the list.
    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        let location = NSPoint(x: point.x, y: window.frame.height - point.y)
        return NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
    }

    private func click(at point: NSPoint, in window: NSWindow, flags: NSEvent.ModifierFlags = []) {
        window.sendEvent(mouse(.leftMouseDown, at: point, in: window))
        window.sendEvent(mouse(.leftMouseUp, at: point, in: window, flags: flags))
    }

    private func press(_ characters: String, keyCode: UInt16 = 0, in window: NSWindow) {
        window.sendEvent(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        )!)
    }

    @Test func pointerClicksAndKeysReachTheRows() throws {
        let log = Log()
        let window = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        var cancelled = false
        window.onCancel = { cancelled = true }
        let entries = [header("a", log: log), row("1", log: log), row("2", log: log), header("b", log: log), row("3", log: log)]
        let (list, selection) = makeList(entries, log: log, in: window)

        // Header 36pt, row 1 50pt and its separator: row 2 starts at 87.
        list.mouseMoved(with: mouse(.mouseMoved, at: NSPoint(x: 200, y: 100), in: window))
        #expect(selection.selectedID == "2")
        #expect(selection.isPointerDriven)
        list.displayIfNeeded()

        // The table view passes clicks on to the rows and their buttons, which replace the time.
        click(at: NSPoint(x: 200, y: 110), in: window)
        #expect(log.events.last == "open 2")
        click(at: NSPoint(x: 460 - 16 - 12, y: 87 + 17), in: window)
        #expect(log.events.last == "button 2")
        click(at: NSPoint(x: 100, y: 20), in: window, flags: .option)
        #expect(log.events.last == "toggle a all")
        click(at: NSPoint(x: 460 - 12 - 12, y: 21), in: window)
        #expect(log.events.last == "mark all a")

        list.takeFocus()
        press("j", in: window)
        #expect(selection.selectedID == "3")
        #expect(!selection.isPointerDriven)
        press("r", in: window)
        #expect(log.events.last == "markRead 3")
        press(String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)), keyCode: 126, in: window)
        #expect(selection.selectedID == "2")
        press("\r", keyCode: 36, in: window)
        #expect(log.events.last == "open 2")
        // Esc closes the panel.
        press("\u{1b}", keyCode: 53, in: window)
        #expect(cancelled)
    }

    @Test func updatesKeepRowsAndSeparatorsInStep() throws {
        let log = Log()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        let (list, _) = makeList([header("a", log: log), row("1", log: log), row("2", log: log), header("b", log: log), row("3", log: log)], log: log, in: window)
        let table = try #require(findTable(in: list))

        // Row 2 goes, row 4 arrives, row 3 moves to the first section.
        let updated = [header("a", log: log), row("1", log: log), row("4", log: log), row("3", log: log), header("b", log: log)]
        list.update(updated, now: .now, dateFormat: .monthDay)
        list.layoutSubtreeIfNeeded()
        #expect(table.numberOfRows == updated.count)
        for (index, entry) in updated.enumerated() {
            let cell = table.rowView(atRow: index, makeIfNecessary: false)?.view(atColumn: 0) as? ListCell
            #expect(cell?.entryID == entry.id)
        }
        // A separator below a row only when another row follows.
        #expect(table.rect(ofRow: 1).height == RowModel.height + 1)
        #expect(table.rect(ofRow: 2).height == RowModel.height + 1)
        #expect(table.rect(ofRow: 3).height == RowModel.height)

        // The context menu names the row's actions.
        let cell = try #require(table.rowView(atRow: 2, makeIfNecessary: false)?.view(atColumn: 0) as? ListCell)
        let menu = try #require(cell.menu(for: mouse(.rightMouseDown, at: .zero, in: window)))
        #expect(menu.items.map(\.title) == ["Open"])
    }

    private func findTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap(findTable).first
    }
}
