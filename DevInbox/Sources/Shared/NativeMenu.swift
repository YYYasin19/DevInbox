import AppKit

/// Shows a native menu below a SwiftUI control. SwiftUI's `Menu` can't take the panel's pill style,
/// and a popover opens slower and doesn't feel like a menu.
enum NativeMenu {
    struct Item {
        let title: String
        var subtitle: String?
        var image: NSImage?
        var isChecked = false
        /// Typed without modifiers while the menu is open, like "1".
        var keyEquivalent = ""
        let action: () -> Void
    }

    /// `frame` is the control's frame in SwiftUI's global (window) coordinates. `title` heads the menu.
    static func show(_ items: [Item], below frame: CGRect, title: String? = nil) {
        guard let view = NSApp.keyWindow?.contentView else { return }
        // SwiftUI's global space starts top left, like the flipped hosting view.
        let y = view.isFlipped ? frame.minY : view.bounds.height - frame.maxY
        show(items, below: NSRect(x: frame.minX, y: y, width: frame.width, height: frame.height), in: view, title: title)
    }

    /// Below `rect`, in `view`'s coordinates.
    static func show(_ items: [Item], below rect: NSRect, in view: NSView, title: String? = nil) {
        let target = Target(actions: items.map(\.action))
        let menu = NSMenu()
        if let title {
            menu.addItem(.sectionHeader(title: title))
        }
        for (index, item) in items.enumerated() {
            let menuItem = NSMenuItem(title: item.title, action: #selector(Target.run(_:)), keyEquivalent: item.keyEquivalent)
            menuItem.keyEquivalentModifierMask = []
            menuItem.target = target
            menuItem.tag = index
            menuItem.subtitle = item.subtitle
            menuItem.image = item.image
            menuItem.state = item.isChecked ? .on : .off
            menu.addItem(menuItem)
        }
        let y = view.isFlipped ? rect.maxY + 4 : rect.minY - 4
        // popUp tracks the menu until it closes, so `target` lives long enough.
        withExtendedLifetime(target) {
            _ = menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: y), in: view)
        }
    }

    private final class Target: NSObject {
        let actions: [() -> Void]

        init(actions: [() -> Void]) {
            self.actions = actions
        }

        @objc func run(_ sender: NSMenuItem) {
            actions[sender.tag]()
        }
    }
}
