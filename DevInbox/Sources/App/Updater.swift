import AppKit
import Sparkle

/// Release builds update themselves from GitHub Releases: Sparkle checks every hour and downloads a new
/// build in the background, then the panel offers to restart into it. Quitting installs it, too.
@Observable
final class Updater: NSObject {
    /// The downloaded version that waits for a restart.
    private(set) var readyVersion: String?

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var installNow: (() -> Void)?

    override init() {
        super.init()
        #if !DEBUG
        // Debug builds run from DerivedData; a release replacing them would be a surprise.
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        #endif
    }

    var isAvailable: Bool { controller != nil }

    @objc func checkForUpdates(_ sender: Any?) {
        controller?.checkForUpdates(sender)
    }

    @objc func installAndRelaunch(_ sender: Any?) {
        guard let installNow else { return }
        Log.info(.app, "Installing update \(readyVersion ?? "?") and relaunching")
        installNow()
    }
}

extension Updater: SPUUpdaterDelegate {
    /// Takes over from Sparkle's install-on-quit, so the restart happens when you confirm it in the panel.
    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        Log.info(.app, "Update \(item.displayVersionString) (\(item.versionString)) downloaded, waiting for a restart")
        readyVersion = item.displayVersionString
        installNow = immediateInstallHandler
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let error = error as NSError
        // "No update found" also ends a cycle with an error.
        guard error.domain != SUSparkleErrorDomain || error.code != Int(SUError.noUpdateError.rawValue) else { return }
        Log.error(.app, "Update failed: \(error.localizedDescription)")
    }
}
