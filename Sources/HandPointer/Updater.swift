import AppKit
import Sparkle

final class Updater: NSObject, SPUStandardUserDriverDelegate, SPUUpdaterDelegate {
    private var updater: SPUUpdater?
    private var driver: VersionedUserDriver?

    static var isAvailable: Bool {
        Bundle.main.bundlePath.hasSuffix(".app")
            && Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
    }

    func start() {
        guard Updater.isAvailable, updater == nil else {
            return
        }
        let driver = VersionedUserDriver(hostBundle: .main, delegate: self)
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        do {
            try updater.start()
        } catch {
            Log.write("updater: could not start: \(error.localizedDescription)")
            return
        }
        self.driver = driver
        self.updater = updater
    }

    func checkForUpdates() {
        updater?.checkForUpdates()
    }

    /// Checks for updates on its own and installs them in the background.
    var autoUpdate: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set {
            updater?.automaticallyChecksForUpdates = newValue
            updater?.automaticallyDownloadsUpdates = newValue
        }
    }

    var lastCheck: Date? { updater?.lastUpdateCheckDate }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Remembers which version the update is, so an error can name it.
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        driver?.updateVersion = item.displayVersionString
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        driver?.updateVersion = nil
    }
}

/// Sparkle's own windows, with the installed version and the update's version added to every
/// error, so a report says which update failed on which version.
private final class VersionedUserDriver: SPUStandardUserDriver {
    var updateVersion: String?

    override func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        let installed = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        var versions = "You have Hand Pointer \(installed)."
        if let update = updateVersion {
            versions += " The update was \(update)."
        }
        let ns = error as NSError
        var info = ns.userInfo
        // Sparkle shows the recovery suggestion as the text when there is one, otherwise the description.
        if let suggestion = ns.localizedRecoverySuggestion {
            info[NSLocalizedRecoverySuggestionErrorKey] = "\(suggestion)\n\n\(versions)"
            info[NSLocalizedDescriptionKey] = ns.localizedDescription
        } else {
            // Our own title instead of Sparkle's "Update Error!", with Sparkle's text below it.
            info[NSLocalizedRecoverySuggestionErrorKey] = "\(ns.localizedDescription)\n\n\(versions)"
            info[NSLocalizedDescriptionKey] = "The update could not be installed"
        }
        super.showUpdaterError(NSError(domain: ns.domain, code: ns.code, userInfo: info), acknowledgement: acknowledgement)
    }
}
