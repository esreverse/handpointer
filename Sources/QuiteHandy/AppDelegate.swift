import AppKit
import ApplicationServices
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let overlay = OverlayController()
    private let settings = SettingsWindow()
    private let updater = Updater()
    private let welcome = WelcomeWindow()
    private var permissionItem: NSMenuItem?
    private let menu = NSMenu()
    private var toggleItem: NSMenuItem?
    private var clearItem: NSMenuItem?
    private var toolbarItem: NSMenuItem?
    private var soundItem: NSMenuItem?
    private var hotKeys: [ShortcutAction: UInt32] = [:]
    private var hotKeysPaused = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = editingMenu()
        HandAsset.preloadThumbnails(PointerStyle.allCases.compactMap(\.assetName))
        Log.write("launch \(Bundle.main.bundlePath) trusted=\(AXIsProcessTrusted())")
        CursorHider.enableBackgroundHiding()
        overlay.onActiveChanged = { [weak self] in
            self?.updateIcon()
            self?.syncHotKeys()
        }
        overlay.onSoundChanged = { [weak self] in
            self?.refreshMenu()
        }
        overlay.extraPassThrough = { [weak self] in
            guard self?.statusItem.isVisible == true, let frame = self?.statusItem.button?.window?.frame else {
                return []
            }
            return [frame]
        }
        enableLaunchAtLoginOnFirstRun()
        updater.start()
        setupStatusItem()
        setupSettings()
        registerHotKeys()

        overlay.onNeedsPermission = { [weak self] in
            self?.welcome.show()
        }
        welcome.onTryIt = { [weak self] in
            self?.overlay.activate()
        }
        if !UserDefaults.standard.bool(forKey: WelcomeWindow.shownKey) || !AXIsProcessTrusted() {
            welcome.show()
        } else if !Preferences.showMenuBarIcon {
            // Without the menu bar icon there is nothing to click, so starting the app shows Settings.
            openSettings()
        }
    }

    /// Opening the app again (Finder, Spotlight) shows Settings – the way back in while the
    /// menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        overlay.deactivate()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.isVisible = Preferences.showMenuBarIcon
        NotificationCenter.default.addObserver(forName: Preferences.changed, object: nil, queue: .main) { [weak self] _ in
            guard let item = self?.statusItem, item.isVisible != Preferences.showMenuBarIcon else {
                return
            }
            item.isVisible = Preferences.showMenuBarIcon
        }
        updateIcon()
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        let permission = NSMenuItem(title: "Allow Accessibility", action: #selector(showWelcome), keyEquivalent: "")
        permissionItem = permission
        menu.addItem(permission)
        let toggle = NSMenuItem(title: "", action: #selector(toggle), keyEquivalent: "")
        let clear = NSMenuItem(title: "Clear Drawing", action: #selector(clearInk), keyEquivalent: "")
        let toolbar = NSMenuItem(title: "Show/Hide Toolbar", action: #selector(toggleToolbar), keyEquivalent: "")
        let sound = NSMenuItem(title: "Sound", action: #selector(toggleSound), keyEquivalent: "")
        toggleItem = toggle
        clearItem = clear
        toolbarItem = toolbar
        soundItem = sound
        menu.addItem(toggle)
        menu.addItem(clear)
        menu.addItem(toolbar)
        menu.addItem(sound)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Quite Handy", action: #selector(quit), keyEquivalent: "q")
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(quit)
        menu.items.forEach { $0.target = self }
        menu.delegate = self
    }

    private func setupSettings() {
        settings.applyToggleShortcut = { [weak self] s in
            self?.apply(s, to: .toggle) ?? false
        }
        settings.applyClearShortcut = { [weak self] s in
            self?.apply(s, to: .clear) ?? false
        }
        settings.applyToolbarShortcut = { [weak self] s in
            self?.apply(s, to: .toolbar) ?? false
        }
        settings.applyRainbowInkShortcut = { [weak self] s in
            self?.apply(s, to: .rainbowInk) ?? false
        }
        settings.applyMatchInkShortcut = { [weak self] s in
            self?.apply(s, to: .matchInk) ?? false
        }
        settings.applyNextPointerShortcut = { [weak self] s in
            self?.apply(s, to: .nextPointer) ?? false
        }
        settings.applyPreviousPointerShortcut = { [weak self] s in
            self?.apply(s, to: .previousPointer) ?? false
        }
        settings.applySoundShortcut = { [weak self] s in
            self?.apply(s, to: .sound) ?? false
        }
        settings.applyUndoShortcut = { [weak self] s in
            self?.apply(s, to: .undo) ?? false
        }
        settings.applyRedoShortcut = { [weak self] s in
            self?.apply(s, to: .redo) ?? false
        }
        settings.updater = Updater.isAvailable ? updater : nil
        settings.onRecording = { [weak self] recording in
            if recording {
                self?.unregisterHotKeys()
            } else {
                self?.registerHotKeys()
            }
        }
    }

    /// Left-click turns the pointer on or off, right-click (or Control-click) opens the menu.
    @objc private func statusClicked() {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        guard wantsMenu else {
            overlay.toggle()
            return
        }
        refreshMenu()
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    func menuWillOpen(_ menu: NSMenu) {
        overlay.suspendInput(true)
    }

    func menuDidClose(_ menu: NSMenu) {
        overlay.suspendInput(false)
    }

    /// Shows a shortcut the way macOS does: right-aligned and dimmed.
    private func setShortcut(_ item: NSMenuItem?, _ shortcut: Shortcut) {
        let key = shortcut.menuKey
        item?.keyEquivalent = key.key
        item?.keyEquivalentModifierMask = key.modifiers
    }

    @objc private func toggleToolbar() {
        overlay.toggleToolbar()
    }

    private func refreshMenu() {
        toggleItem?.title = "Toggle On/Off"
        setShortcut(toggleItem, Preferences.toggleShortcut)
        setShortcut(clearItem, Preferences.clearShortcut)
        setShortcut(toolbarItem, Preferences.toolbarShortcut)
        soundItem?.state = overlay.soundOn ? .on : .off
        permissionItem?.isHidden = AXIsProcessTrusted()
    }

    private enum ShortcutAction: CaseIterable {
        case toggle, clear, undo, redo, toolbar, rainbowInk, matchInk, nextPointer, previousPointer, sound, settings

        /// Everything but the on/off shortcut is only grabbed while the pointer is on, so keys like
        /// ⌘Z or ⌘, keep working in other apps the rest of the time.
        var onlyWhileActive: Bool { self != .toggle }

        var shortcut: Shortcut {
            get {
                switch self {
                case .toggle: return Preferences.toggleShortcut
                case .clear: return Preferences.clearShortcut
                case .undo: return Preferences.undoShortcut
                case .redo: return Preferences.redoShortcut
                case .toolbar: return Preferences.toolbarShortcut
                case .rainbowInk: return Preferences.rainbowInkShortcut
                case .matchInk: return Preferences.matchInkShortcut
                case .nextPointer: return Preferences.nextPointerShortcut
                case .previousPointer: return Preferences.previousPointerShortcut
                case .sound: return Preferences.soundShortcut
                case .settings: return Shortcut(keyCode: UInt32(kVK_ANSI_Comma), modifiers: UInt32(cmdKey), display: "⌘,")
                }
            }
            nonmutating set {
                switch self {
                case .toggle: Preferences.toggleShortcut = newValue
                case .clear: Preferences.clearShortcut = newValue
                case .undo: Preferences.undoShortcut = newValue
                case .redo: Preferences.redoShortcut = newValue
                case .toolbar: Preferences.toolbarShortcut = newValue
                case .rainbowInk: Preferences.rainbowInkShortcut = newValue
                case .matchInk: Preferences.matchInkShortcut = newValue
                case .nextPointer: Preferences.nextPointerShortcut = newValue
                case .previousPointer: Preferences.previousPointerShortcut = newValue
                case .sound: Preferences.soundShortcut = newValue
                case .settings: break
                }
            }
        }
    }

    private func apply(_ s: Shortcut, to action: ShortcutAction) -> Bool {
        unregisterHotKeys()
        let old = action.shortcut
        action.shortcut = s
        if registerHotKeys() {
            return true
        }
        unregisterHotKeys()
        action.shortcut = old
        registerHotKeys()
        return false
    }

    private var repeatTimer: Timer?

    /// Holding the next/previous pointer or undo/redo key repeats it, like a held key in a text field.
    private func startRepeat(_ action: ShortcutAction, _ step: @escaping () -> Void) {
        repeatTimer?.invalidate()
        let code = CGKeyCode(action.shortcut.keyCode)
        let start = Date()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] timer in
            guard CGEventSource.keyState(.combinedSessionState, key: code), self?.overlay.isActive == true else {
                timer.invalidate()
                return
            }
            if Date().timeIntervalSince(start) >= 0.4 {
                step()
            }
        }
    }

    private func perform(_ action: ShortcutAction) {
        switch action {
        case .toggle: overlay.toggle()
        case .clear: overlay.clearInk()
        case .undo:
            overlay.undoInk()
            startRepeat(action) { [weak self] in self?.overlay.undoInk() }
        case .redo:
            overlay.redoInk()
            startRepeat(action) { [weak self] in self?.overlay.redoInk() }
        case .toolbar: overlay.toggleToolbar()
        case .rainbowInk: Preferences.inkChoice = .rainbow
        case .matchInk: Preferences.inkChoice = .match
        case .nextPointer:
            overlay.cyclePointer(by: 1)
            startRepeat(action) { [weak self] in self?.overlay.cyclePointer(by: 1) }
        case .previousPointer:
            overlay.cyclePointer(by: -1)
            startRepeat(action) { [weak self] in self?.overlay.cyclePointer(by: -1) }
        case .sound: overlay.soundOn.toggle()
        case .settings: openSettings()
        }
    }

    @discardableResult
    private func registerHotKeys() -> Bool {
        hotKeysPaused = false
        return syncHotKeys()
    }

    /// Registers each shortcut that should be live right now. A shortcut without ⌃, ⌥ or ⌘
    /// (for example a lone ⇥) is only grabbed while the pointer is on, so the key keeps working
    /// normally the rest of the time.
    @discardableResult
    private func syncHotKeys() -> Bool {
        var ok = true
        for action in ShortcutAction.allCases {
            let s = action.shortcut
            let wanted = !hotKeysPaused && (!action.onlyWhileActive || overlay.isActive)
            if wanted && hotKeys[action] == nil {
                hotKeys[action] = HotKeyCenter.shared.register(keyCode: s.keyCode, modifiers: s.modifiers) { [weak self] in
                    self?.perform(action)
                }
                if hotKeys[action] == nil {
                    ok = false
                }
            } else if !wanted, let id = hotKeys[action] {
                HotKeyCenter.shared.unregister(id)
                hotKeys[action] = nil
            }
        }
        return ok
    }

    private func unregisterHotKeys() {
        for id in hotKeys.values {
            HotKeyCenter.shared.unregister(id)
        }
        hotKeys = [:]
        hotKeysPaused = true
    }

    @objc private func toggle() {
        overlay.toggle()
    }

    @objc private func clearInk() {
        overlay.clearInk()
    }

    @objc private func toggleSound() {
        overlay.soundOn.toggle()
    }

    @objc private func openSettings() {
        overlay.exit()
        settings.show()
    }

    @objc private func showWelcome() {
        overlay.exit()
        welcome.show()
    }

    @objc private func quit() {
        overlay.deactivate()
        NSApp.terminate(nil)
    }

    private func enableLaunchAtLoginOnFirstRun() {
        let key = "loginItemSetUp"
        let path = Bundle.main.bundlePath
        let installed = path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
        guard installed, !UserDefaults.standard.bool(forKey: key) else {
            return
        }
        UserDefaults.standard.set(true, forKey: key)
        Preferences.launchAtLogin = true
        Log.write("first run: open at login = \(Preferences.launchAtLogin)")
    }

    private func updateIcon() {
        let on = overlay.isActive
        let image = Bundle.main.image(forResource: on ? "menubar_on" : "menubar_off")
            ?? NSImage(systemSymbolName: on ? "hand.point.up.left.fill" : "hand.point.up.left",
                       accessibilityDescription: "Quite Handy")
        image?.size = NSSize(width: 18, height: 18)
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = overlay.isActive
            ? "Quite Handy is on, click to turn off, right-click for the menu"
            : "Quite Handy, click to turn on, right-click for the menu"
    }

    private func editingMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit Quite Handy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }
}
