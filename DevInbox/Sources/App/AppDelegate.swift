import AppKit
import UserNotifications

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var statusItemController: StatusItemController?
    private var settingsWindowController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hosted unit tests launch the app; keep it inert there.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        Log.info(.app, "DevInbox \(version) (\(build)) started, \(ProcessInfo.processInfo.operatingSystemVersionString), pid \(ProcessInfo.processInfo.processIdentifier)")

        #if DEBUG
        // Made-up data only: no sign-in, no status item, no shortcut.
        if let directory = DemoSnapshot.outputDirectory {
            DemoSnapshot.run(into: directory)
            return
        }
        #endif

        let model = AppModel()
        self.model = model
        NSApp.mainMenu = MainMenu.make(target: self)
        statusItemController = StatusItemController(model: model)
        model.openSettingsAction = { [weak self] in self?.showSettings(nil) }
        model.closePanelAction = { [weak self] in self?.statusItemController?.closePanel() }
        UNUserNotificationCenter.current().delegate = self
        model.start()

        #if DEBUG
        if ScrollBenchmark.isRequested {
            ScrollBenchmark.run(model: model)
        }
        if let directory = DebugSnapshot.outputDirectory {
            DebugSnapshot.run(model: model, into: directory)
        }
        #endif
    }

    @objc func showSettings(_ sender: Any?) {
        guard let model else { return }
        statusItemController?.closePanel()
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(model: model)
        }
        settingsWindowController?.show()
    }

    @objc func refresh(_ sender: Any?) {
        model?.session?.refreshAll()
    }

    /// ⌘Z takes back the last Done, Snooze or Dismiss while its toast shows.
    @objc func undoLastAction(_ sender: Any?) {
        model?.undo.undo()
    }

    /// A pending Done still has to reach GitHub; quitting waits for it, but not for long.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Log.info(.app, "Quitting")
        guard let pending = model?.undo.commit() else { return .terminateNow }
        Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await pending.value }
                group.addTask { try? await Task.sleep(for: .seconds(3)) }
                await group.next()
                group.cancelAll()
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.flush()
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(undoLastAction(_:)) {
            return model?.undo.current != nil
        }
        return true
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let threadID = response.notification.request.content.userInfo[BannerNotifier.threadIDKey] as? String
        await MainActor.run {
            // Threads done or gone since the banner was posted fall back to the panel.
            if let threadID, model?.openThread(id: threadID) == true { return }
            statusItemController?.openPanel()
        }
    }
}

enum MainMenu {
    /// Menu-bar apps have no visible menu, but key equivalents (⌘Q, ⌘W, ⌘C, ⌘,) still go through it.
    static func make(target: AppDelegate) -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About DevInbox", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        settings.target = target
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit DevInbox", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: appMenu, title: "DevInbox")

        let editMenu = NSMenu(title: "Edit")
        let undo = editMenu.addItem(withTitle: "Undo", action: #selector(AppDelegate.undoLastAction(_:)), keyEquivalent: "z")
        undo.target = target
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu: editMenu, title: "Edit")

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu: windowMenu, title: "Window")

        return main
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
