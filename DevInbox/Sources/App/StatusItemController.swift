import AppKit
import SwiftUI

final class StatusItemController: NSObject {
    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private lazy var panel = PanelController(rootView: PanelRootView(model: model)) { [weak self] in
        self?.statusItem.button?.highlight(false)
        self?.model.panelDidClose()
    }
    /// Glows at the pill's corner while a review request's notification is unread. A subview, because
    /// the pill is a template image and can't carry color.
    private let reviewDot = ReviewDotView(frame: NSRect(x: 0, y: 0, width: 9, height: 9))
    private lazy var shortcut = GlobalShortcut { [weak self] in self?.togglePanel() }

    init(model: AppModel) {
        self.model = model
        super.init()
        _ = panel // built at launch rather than on the first click, so even the first open is instant
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            // On mouse-down, like the system's status items: the panel is there before the click ends.
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.imagePosition = .imageOnly
            button.addSubview(reviewDot)
            // The item's width follows the pill, so the dot moves whenever the button resizes.
            button.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(positionReviewDot), name: NSView.frameDidChangeNotification, object: button
            )
        }
        observeModel()
        observeShortcut()
    }

    func openPanel() {
        guard let button = statusItem.button else { return }
        model.panelWillOpen()
        panel.show(below: button)
        button.highlight(true)
        model.panelDidOpen()
    }

    func closePanel() {
        panel.hide()
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseDown {
            showContextMenu()
        } else {
            togglePanel()
        }
    }

    private func togglePanel() {
        if panel.isVisible {
            closePanel()
        } else {
            openPanel()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false // otherwise `isEnabled` below is ignored
        let refresh = menu.addItem(withTitle: "Refresh", action: #selector(AppDelegate.refresh(_:)), keyEquivalent: "")
        refresh.target = NSApp.delegate
        refresh.isEnabled = model.session != nil
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: "")
        settings.target = NSApp.delegate
        let updater = model.updater
        if let version = updater.readyVersion {
            menu.addItem(withTitle: "Restart to Update to \(version)", action: #selector(Updater.installAndRelaunch(_:)), keyEquivalent: "").target = updater
        } else if updater.isAvailable {
            menu.addItem(withTitle: "Check for Updates…", action: #selector(Updater.checkForUpdates(_:)), keyEquivalent: "").target = updater
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit DevInbox", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    /// Keeps the global shortcut in step with Settings, and quiet while Settings records a new one.
    private func observeShortcut() {
        let (value, isRecording) = withObservationTracking {
            (model.settings.openPanelShortcut, model.isRecordingShortcut)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeShortcut() }
        }
        let isRegistered = shortcut.register(isRecording ? nil : value)
        if !isRecording, model.isShortcutTaken == isRegistered {
            model.isShortcutTaken = !isRegistered
        }
    }

    // MARK: - Rendering

    private func observeModel() {
        let state = withObservationTracking {
            (model.menuBarState, model.settings.showUnreadCount, model.settings.showsReviewDot)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeModel() }
        }
        render(state.0, showCounts: state.1, showsReviewDot: state.2)
    }

    private func render(_ state: MenuBarState, showCounts: Bool, showsReviewDot: Bool) {
        guard let button = statusItem.button else { return }
        let hasCounts = state.unread > 0 || state.pendingReviews > 0
        if state.isSignedIn && showCounts && hasCounts {
            let scale = max(button.window?.backingScaleFactor ?? 2, 2)
            button.image = StatusPill.image(unread: state.unread, reviews: state.pendingReviews, scale: scale)
        } else {
            button.image = NSImage.icon(.inbox, size: 17)
        }
        button.title = ""
        button.setAccessibilityLabel("DevInbox")
        reviewDot.isHidden = !(state.isSignedIn && showsReviewDot && state.newReviewRequests > 0)
        positionReviewDot()

        var summary: [String] = []
        if !state.isSignedIn {
            summary.append("Not signed in")
        } else {
            summary.append(state.unread == 1 ? "1 new notification" : "\(state.unread) new notifications")
            if state.pendingReviews > 0 {
                var reviews = state.pendingReviews == 1 ? "1 review waiting" : "\(state.pendingReviews) reviews waiting"
                if state.newReviewRequests > 0 { reviews += " (\(state.newReviewRequests) new)" }
                summary.append(reviews)
            }
        }
        button.toolTip = "DevInbox — " + summary.joined(separator: " · ")
        if !panel.isVisible { panel.prepare() }
    }

    /// Puts the dot on the top-right corner of the image, which the button centers.
    @objc private func positionReviewDot() {
        guard let button = statusItem.button, let image = button.image else { return }
        let bounds = button.bounds
        let imageRect = NSRect(
            x: ((bounds.width - image.size.width) / 2).rounded(),
            y: ((bounds.height - image.size.height) / 2).rounded(),
            width: image.size.width,
            height: image.size.height
        )
        let size = reviewDot.frame.size
        // Centered a little inside the corner, so most of the dot sits on the pill.
        let top = button.isFlipped ? imageRect.minY + 2 : imageRect.maxY - 2
        reviewDot.frame.origin = NSPoint(x: imageRect.maxX - size.width / 2 - 2, y: top - size.height / 2)
    }
}

/// A small red dot with a soft glow. Its ring has the pill's color, so the dot stays visible on a red
/// wallpaper too.
private final class ReviewDotView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
        guard let layer else { return }
        layer.backgroundColor = NSColor.systemRed.cgColor
        layer.cornerRadius = frame.width / 2
        layer.borderWidth = 1.5
        layer.masksToBounds = false
        layer.shadowColor = NSColor.systemRed.cgColor
        layer.shadowOpacity = 0.9
        layer.shadowRadius = 2.5
        layer.shadowOffset = .zero
        updateRing()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateRing()
    }

    /// Template images in the menu bar are white on a dark bar and black on a light one.
    private func updateRing() {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark]).map {
            $0 == .darkAqua || $0 == .vibrantDark
        } ?? false
        layer?.borderColor = (isDark ? NSColor.white : NSColor.black).cgColor
    }

    // Clicks go to the status item button underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
