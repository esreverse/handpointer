import AppKit
import Sparkle

final class Updater: NSObject, SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController?

    static var isAvailable: Bool {
        Bundle.main.bundlePath.hasSuffix(".app")
            && Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
    }

    func start() {
        guard Updater.isAvailable, controller == nil else {
            return
        }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// Checks for updates on its own and installs them in the background.
    var autoUpdate: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            controller?.updater.automaticallyChecksForUpdates = newValue
            controller?.updater.automaticallyDownloadsUpdates = newValue
        }
    }

    var lastCheck: Date? { controller?.updater.lastUpdateCheckDate }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        NSApp.activate(ignoringOtherApps: true)
    }
}
