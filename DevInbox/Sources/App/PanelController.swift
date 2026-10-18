import AppKit
import SwiftUI

/// A borderless panel below the status item. Unlike `MenuBarExtra`, it can be opened and closed
/// programmatically, takes keyboard focus reliably and closes on Esc or when clicking elsewhere.
final class PanelController: NSObject {
    static let size = NSSize(width: 460, height: 600)

    private let panel: KeyablePanel
    private let hostingView: NSHostingView<AnyView>
    private let onHide: () -> Void
    private var outsideClickMonitor: Any?
    private var deactivationObserver: NSObjectProtocol?

    init(rootView: some View, onHide: @escaping () -> Void) {
        self.onHide = onHide
        hostingView = NSHostingView(rootView: AnyView(rootView))
        panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none // opened many times a day: no fade
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.onCancel = { [weak self] in self?.hide() }

        // The SwiftUI root draws the opaque, rounded surface; the window itself stays clear.
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        prepare()
    }

    var isVisible: Bool { panel.isVisible }

    /// Lays out the hidden panel for the current data, so opening it only has to draw.
    func prepare() {
        hostingView.layoutSubtreeIfNeeded()
    }

    func show(below button: NSStatusBarButton) {
        let screen = button.window?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        var origin: NSPoint
        if let itemFrame = Self.frameOnScreen(of: button) {
            origin = NSPoint(x: itemFrame.midX - Self.size.width / 2, y: itemFrame.minY - 6 - Self.size.height)
        } else {
            // macOS hides status items when the menu bar has no room; the shortcut still opens the panel.
            Log.info(.app, "The menu bar item is hidden, opening the panel at the top right")
            origin = NSPoint(x: visible.maxX, y: visible.maxY - 6 - Self.size.height)
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - Self.size.width - 8)
        panel.setFrame(NSRect(origin: origin, size: Self.size), display: true)

        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()

        removeMonitors() // show() can run while already visible, e.g. from a banner click
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        deactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    /// The status item in screen coordinates, or nil while macOS keeps it out of the menu bar.
    private static func frameOnScreen(of button: NSStatusBarButton) -> NSRect? {
        guard let window = button.window, window.occlusionState.contains(.visible) else { return nil }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        return NSScreen.screens.contains { $0.frame.intersects(frame) } ? frame : nil
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        removeMonitors()
        onHide()
    }

    private func removeMonitors() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
        outsideClickMonitor = nil
        if let deactivationObserver {
            NotificationCenter.default.removeObserver(deactivationObserver)
        }
        deactivationObserver = nil
    }
}

final class KeyablePanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
