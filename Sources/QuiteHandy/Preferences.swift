import AppKit
import Carbon.HIToolbox
import ServiceManagement

struct Shortcut: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var display: String

    /// A single-letter shortcut for the key that types `letter` on the current keyboard layout
    /// (so "Y" is the Y key on a German keyboard too, where Y and Z swap places).
    static func letter(_ letter: Character, fallback: Int, modifiers: UInt32 = 0) -> Shortcut {
        let code = keyCode(typing: letter) ?? UInt32(fallback)
        var symbols = ""
        if modifiers & UInt32(controlKey) != 0 { symbols += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { symbols += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { symbols += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { symbols += "⌘" }
        return Shortcut(keyCode: code, modifiers: modifiers, display: symbols + String(letter).uppercased())
    }

    private static func keyCode(typing letter: Character) -> UInt32? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        let wanted = String(letter).lowercased()
        return data.withUnsafeBytes { buffer -> UInt32? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return nil
            }
            for code in 0..<128 {
                var deadKeys: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
                if status == noErr, length > 0, String(utf16CodeUnits: chars, count: length) == wanted {
                    return UInt32(code)
                }
            }
            return nil
        }
    }

    /// A shortcut without ⌃, ⌥ or ⌘, such as a lone ⇥. Only safe to grab while the pointer is on.
    var isBare: Bool { modifiers & UInt32(controlKey | optionKey | cmdKey) == 0 }

    /// Key equivalent and modifiers for showing this shortcut in a menu,
    /// where macOS draws it right-aligned and dimmed.
    var menuKey: (key: String, modifiers: NSEvent.ModifierFlags) {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        func function(_ code: Int) -> String { String(Character(UnicodeScalar(UInt16(code))!)) }
        let special: [Int: String] = [
            kVK_Tab: "\t", kVK_Return: "\r", kVK_Space: " ", kVK_Delete: "\u{8}", kVK_Escape: "\u{1b}",
            kVK_ForwardDelete: function(NSDeleteFunctionKey),
            kVK_LeftArrow: function(NSLeftArrowFunctionKey), kVK_RightArrow: function(NSRightArrowFunctionKey),
            kVK_UpArrow: function(NSUpArrowFunctionKey), kVK_DownArrow: function(NSDownArrowFunctionKey),
            kVK_Home: function(NSHomeFunctionKey), kVK_End: function(NSEndFunctionKey),
            kVK_PageUp: function(NSPageUpFunctionKey), kVK_PageDown: function(NSPageDownFunctionKey),
            kVK_F1: function(NSF1FunctionKey), kVK_F2: function(NSF2FunctionKey), kVK_F3: function(NSF3FunctionKey),
            kVK_F4: function(NSF4FunctionKey), kVK_F5: function(NSF5FunctionKey), kVK_F6: function(NSF6FunctionKey),
            kVK_F7: function(NSF7FunctionKey), kVK_F8: function(NSF8FunctionKey), kVK_F9: function(NSF9FunctionKey),
            kVK_F10: function(NSF10FunctionKey), kVK_F11: function(NSF11FunctionKey), kVK_F12: function(NSF12FunctionKey),
        ]
        if let key = special[Int(keyCode)] {
            return (key, flags)
        }
        let name = display.filter { !"⌃⌥⇧⌘".contains($0) }
        return (name.lowercased(), flags)
    }

    static let toggleDefault = Shortcut(keyCode: UInt32(kVK_Tab), modifiers: UInt32(controlKey), display: "⌃⇥")
    static let clearDefault = Shortcut.letter("R", fallback: kVK_ANSI_R)
    static let toolbarDefault = Shortcut.letter("T", fallback: kVK_ANSI_T)
    static let rainbowInkDefault = Shortcut.letter("A", fallback: kVK_ANSI_A, modifiers: UInt32(shiftKey))
    static let matchInkDefault = Shortcut.letter("A", fallback: kVK_ANSI_A)
    static let nextPointerDefault = Shortcut.letter("X", fallback: kVK_ANSI_X)
    static let nextInkDefault = Shortcut.letter("V", fallback: kVK_ANSI_V)
    static let copyScreenDefault = Shortcut(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey), display: "⌘C")
    static let saveScreenDefault = Shortcut(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(cmdKey), display: "⌘S")
    static let previousInkDefault = Shortcut.letter("C", fallback: kVK_ANSI_C)
    static let previousPointerDefault = Shortcut.letter("Y", fallback: kVK_ANSI_Y)
    static let soundDefault = Shortcut.letter("S", fallback: kVK_ANSI_S)
    static let undoDefault = Shortcut.letter("Z", fallback: kVK_ANSI_Z, modifiers: UInt32(cmdKey))
    static let redoDefault = Shortcut.letter("Z", fallback: kVK_ANSI_Z, modifiers: UInt32(shiftKey | cmdKey))
}

enum InteractKey: String, CaseIterable {
    case option, command, control, space, tab, off

    var title: String {
        switch self {
        case .option: return "⌥ Option"
        case .command: return "⌘ Command"
        case .control: return "⌃ Control"
        case .space: return "Space"
        case .tab: return "⇥ Tab"
        case .off: return "Off"
        }
    }

    var symbol: String {
        switch self {
        case .option: return "⌥"
        case .command: return "⌘"
        case .control: return "⌃"
        case .space: return "Space"
        case .tab: return "⇥"
        case .off: return ""
        }
    }

    var cgFlags: CGEventFlags {
        switch self {
        case .option: return .maskAlternate
        case .command: return .maskCommand
        case .control: return .maskControl
        case .space: return HeldKeys.space
        case .tab: return HeldKeys.tab
        case .off: return []
        }
    }
}

/// How much drawn lines are smoothed while you draw.
enum StrokeSmoothing: Int, CaseIterable {
    case off, veryLight, light, medium

    var title: String {
        switch self {
        case .off: return "Off"
        case .veryLight: return "Very light"
        case .light: return "Light"
        case .medium: return "Medium"
        }
    }

    /// How many neighbours on each side are averaged into each point of the line
    /// (points are about 3 pt apart, so medium smooths over roughly ±30 pt).
    var window: Int {
        switch self {
        case .off: return 0
        case .veryLight: return 2
        case .light: return 5
        case .medium: return 10
        }
    }
}

/// A modifier key that is held down, for example to zoom while it is pressed.
enum HoldKey: String, CaseIterable {
    case shift, control, option, command, space, tab, off

    var title: String {
        switch self {
        case .shift: return "⇧ Shift"
        case .control: return "⌃ Control"
        case .option: return "⌥ Option"
        case .command: return "⌘ Command"
        case .space: return "Space"
        case .tab: return "⇥ Tab"
        case .off: return "Off"
        }
    }

    var cgFlags: CGEventFlags {
        switch self {
        case .shift: return .maskShift
        case .control: return .maskControl
        case .option: return .maskAlternate
        case .command: return .maskCommand
        case .space: return HeldKeys.space
        case .tab: return HeldKeys.tab
        case .off: return []
        }
    }
}

/// Space and Tab can be held like ⇧⌃⌥⌘ while the pointer is on. They have no modifier flag of
/// their own, so the event tap keeps track of them and they get made-up flag bits that no real
/// key uses. `current` is the real modifier state plus those bits.
enum HeldKeys {
    static let space = CGEventFlags(rawValue: 1 << 40)
    static let tab = CGEventFlags(rawValue: 1 << 41)
    private static let lock = NSLock()
    private static var held: CGEventFlags = []

    static var current: CGEventFlags {
        CGEventSource.flagsState(.hidSystemState).union(lock.withLock { held })
    }

    static func isHeld(_ flag: CGEventFlags) -> Bool {
        lock.withLock { held.contains(flag) }
    }

    static func set(_ flag: CGEventFlags, down: Bool) {
        lock.withLock {
            if down {
                held.insert(flag)
            } else {
                held.remove(flag)
            }
        }
    }

    static func reset() {
        lock.withLock { held = [] }
    }

    /// The made-up flag for a key code, if Space or Tab is set as one of the hold keys.
    static func flag(forKeyCode code: Int64) -> CGEventFlags? {
        let flag: CGEventFlags
        switch code {
        case 49: flag = space
        case 48: flag = tab
        default: return nil
        }
        let used = [Preferences.interactKey.cgFlags, Preferences.stampKey.cgFlags,
                    Preferences.zoomKey.cgFlags, Preferences.loupeAdjustKey.cgFlags]
        return used.contains(flag) ? flag : nil
    }
}

enum InkChoice: String, CaseIterable {
    case match, rainbow, red, yellow, green, blue, white, gray, black

    var title: String {
        switch self {
        case .rainbow: return "Rainbow"
        case .match: return "Match the pointer"
        case .red: return "Red"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .blue: return "Blue"
        case .white: return "White"
        case .gray: return "Gray"
        case .black: return "Black"
        }
    }

    var color: CGColor? {
        switch self {
        case .rainbow, .match: return nil
        case .red: return Ink.red
        case .yellow: return Ink.hex(0xFFCC00)
        case .green: return Ink.hex(0x30C25A)
        case .blue: return Ink.hex(0x0A84FF)
        case .white: return Ink.hex(0xFFFFFF)
        case .gray: return Ink.hex(0x8E8E93)
        case .black: return Ink.hex(0x1D1D21)
        }
    }

    func resolved(for style: PointerStyle) -> CGColor {
        if self == .rainbow {
            return Ink.red
        }
        return color ?? style.inkColor
    }
}

enum Preferences {
    static let changed = Notification.Name("QuiteHandyPreferencesChanged")
    private static let defaults = UserDefaults.standard

    static var toggleShortcut: Shortcut {
        get { loadShortcut("shortcut.toggle") ?? .toggleDefault }
        set { saveShortcut(newValue, "shortcut.toggle") }
    }

    static var clearShortcut: Shortcut {
        get { loadShortcut("shortcut.clear") ?? .clearDefault }
        set { saveShortcut(newValue, "shortcut.clear") }
    }

    static var toolbarShortcut: Shortcut {
        get { loadShortcut("shortcut.toolbar") ?? .toolbarDefault }
        set { saveShortcut(newValue, "shortcut.toolbar") }
    }

    /// Copies a picture of the screen, with drawings and whiteboards, to the clipboard.
    static var copyScreenShortcut: Shortcut {
        get { loadShortcut("shortcut.copyScreen") ?? .copyScreenDefault }
        set { saveShortcut(newValue, "shortcut.copyScreen") }
    }

    /// Saves that picture on the Desktop.
    static var saveScreenShortcut: Shortcut {
        get { loadShortcut("shortcut.saveScreen") ?? .saveScreenDefault }
        set { saveShortcut(newValue, "shortcut.saveScreen") }
    }

    static var nextInkShortcut: Shortcut {
        get { loadShortcut("shortcut.nextInk") ?? .nextInkDefault }
        set { saveShortcut(newValue, "shortcut.nextInk") }
    }

    static var previousInkShortcut: Shortcut {
        get { loadShortcut("shortcut.previousInk") ?? .previousInkDefault }
        set { saveShortcut(newValue, "shortcut.previousInk") }
    }

    static var nextPointerShortcut: Shortcut {
        get { loadShortcut("shortcut.nextPointer") ?? .nextPointerDefault }
        set { saveShortcut(newValue, "shortcut.nextPointer") }
    }

    static var previousPointerShortcut: Shortcut {
        get { loadShortcut("shortcut.previousPointer") ?? .previousPointerDefault }
        set { saveShortcut(newValue, "shortcut.previousPointer") }
    }

    static var rainbowInkShortcut: Shortcut {
        get { loadShortcut("shortcut.rainbowInk") ?? .rainbowInkDefault }
        set { saveShortcut(newValue, "shortcut.rainbowInk") }
    }

    static var matchInkShortcut: Shortcut {
        get { loadShortcut("shortcut.matchInk") ?? .matchInkDefault }
        set { saveShortcut(newValue, "shortcut.matchInk") }
    }

    static var soundShortcut: Shortcut {
        get { loadShortcut("shortcut.sound") ?? .soundDefault }
        set { saveShortcut(newValue, "shortcut.sound") }
    }

    static var undoShortcut: Shortcut {
        get { loadShortcut("shortcut.undo") ?? .undoDefault }
        set { saveShortcut(newValue, "shortcut.undo") }
    }

    static var redoShortcut: Shortcut {
        get { loadShortcut("shortcut.redo") ?? .redoDefault }
        set { saveShortcut(newValue, "shortcut.redo") }
    }

    static let pointerSizeRange: ClosedRange<CGFloat> = 0.08...0.20

    static var pointerSize: CGFloat {
        get { (defaults.object(forKey: "pointerSize") as? Double).map { CGFloat($0) } ?? 0.14 }
        set { set(Double(newValue), "pointerSize") }
    }


    static var fadeSeconds: Double {
        get { defaults.object(forKey: "fadeSeconds") as? Double ?? 0 }
        set { set(newValue, "fadeSeconds") }
    }

    static var handSound: Bool {
        get { defaults.object(forKey: "sound.hands") as? Bool ?? true }
        set { set(newValue, "sound.hands") }
    }

    static var tapSound: TapSoundChoice {
        get { defaults.string(forKey: "tapSound").flatMap(TapSoundChoice.init(rawValue:)) ?? .pop }
        set { set(newValue.rawValue, "tapSound") }
    }

    /// Whether the simple cursor taps too (stored under its old key, from when the laser dot shared it).
    static var colorPointerSound: Bool {
        get { defaults.object(forKey: "sound.laser") as? Bool ?? false }
        set { set(newValue, "sound.laser") }
    }

    static var interactKeepsHand: Bool {
        get { defaults.bool(forKey: "interactKeepsHand") }
        set { set(newValue, "interactKeepsHand") }
    }

    static var interactKey: InteractKey {
        get { defaults.string(forKey: "interactKey").flatMap(InteractKey.init(rawValue:)) ?? .command }
        set { set(newValue.rawValue, "interactKey") }
    }

    static var inkChoice: InkChoice {
        get { defaults.string(forKey: "inkChoice").flatMap(InkChoice.init(rawValue:)) ?? .rainbow }
        set { set(newValue.rawValue, "inkChoice") }
    }

    /// Where the toolbar was dragged to: its centre x and bottom y, relative to the screen's
    /// bottom-left corner. Nil until it is moved; a right-click on its handle clears it.
    static var toolbarPosition: CGPoint? {
        get {
            guard let x = defaults.object(forKey: "toolbarX") as? Double,
                  let y = defaults.object(forKey: "toolbarY") as? Double else {
                return nil
            }
            return CGPoint(x: x, y: y)
        }
        set {
            if let p = newValue {
                defaults.set(Double(p.x), forKey: "toolbarX")
                defaults.set(Double(p.y), forKey: "toolbarY")
            } else {
                defaults.removeObject(forKey: "toolbarX")
                defaults.removeObject(forKey: "toolbarY")
            }
        }
    }

    /// Play the tap sound when you start drawing too, not only on a tap.
    static var soundOnDraw: Bool {
        get { defaults.bool(forKey: "soundOnDraw") }
        set { set(newValue, "soundOnDraw") }
    }

    static var strokeSmoothing: StrokeSmoothing {
        get { StrokeSmoothing(rawValue: defaults.object(forKey: "strokeSmoothing") as? Int ?? 1) ?? .light }
        set { set(newValue.rawValue, "strokeSmoothing") }
    }

    /// A circle grows and fades out where you tap.
    static var tapRipples: Bool {
        get { defaults.object(forKey: "tapRipples") as? Bool ?? true }
        set { set(newValue, "tapRipples") }
    }

    /// The icon in the menu bar. Hidden, opening the app again shows Settings.
    static var showMenuBarIcon: Bool {
        get { defaults.object(forKey: "showMenuBarIcon") as? Bool ?? true }
        set { set(newValue, "showMenuBarIcon") }
    }

    static var showToolbar: Bool {
        get { defaults.object(forKey: "showToolbar") as? Bool ?? true }
        set { set(newValue, "showToolbar") }
    }

    static let rainbowStepChoices = Array(stride(from: 0, through: 90, by: 10))

    /// How many degrees of hue past the end of the last rainbow line the next one starts.
    static var rainbowStep: Int {
        get { min(90, max(0, defaults.object(forKey: "rainbowStep") as? Int ?? 0)) }
        set { set(min(90, max(0, newValue)), "rainbowStep") }
    }

    /// A right click turns the pointer off, like Esc.
    static var rightClickExits: Bool {
        get { defaults.object(forKey: "rightClickExits") as? Bool ?? true }
        set { set(newValue, "rightClickExits") }
    }

    /// Hold this key and click to stamp numbered circles: 1, 2, 3 …
    static var stampKey: HoldKey {
        get { defaults.string(forKey: "stampKey").flatMap(HoldKey.init(rawValue:)) ?? .shift }
        set { set(newValue.rawValue, "stampKey") }
    }

    /// Hold this key while drawing for a straight arrow instead of a free line.
    /// Hold while the flashlight or loupe is open and move the mouse: sideways and up/down work
    /// like swiping (size and zoom), for a mouse that can only scroll one way.
    static var loupeAdjustKey: HoldKey {
        get { defaults.string(forKey: "loupeAdjustKey").flatMap(HoldKey.init(rawValue:)) ?? .option }
        set { set(newValue.rawValue, "loupeAdjustKey") }
    }

    /// Arrows are switched off for now (no setting): the drawing code stays, the key is always Off.
    static var arrowKey: HoldKey {
        get { .off }
        set { set(newValue.rawValue, "arrowKey") }
    }

    /// The flashlight/loupe is always on; only its key can be changed (never to Off).
    static var zoomKey: HoldKey {
        // Tab by default: ⇧ would turn scrolling sideways and starts most screenshot shortcuts,
        // and ⌃ with scrolling is macOS's own screen zoom.
        get { defaults.string(forKey: "zoomKey").flatMap(HoldKey.init(rawValue:)).flatMap { $0 == .off ? nil : $0 } ?? .tab }
        set {
            guard newValue != .off else {
                return
            }
            set(newValue.rawValue, "zoomKey")
        }
    }

    /// At 1× the loupe is a flashlight: it only darkens around the pointer and needs no capture.
    static var isFlashlight: Bool { !zoomOn || !CGPreflightScreenCaptureAccess() }

    /// Zoom has to be turned on on its own (it needs Screen Recording); off, the loupe is a flashlight.
    static var zoomOn: Bool {
        get { defaults.bool(forKey: "zoomOn") }
        set { set(newValue, "zoomOn") }
    }

    /// The factor the loupe uses right now: 1 (flashlight) unless zoom is on and allowed. With zoom
    /// on, 1× keeps capturing (the loupe ring is gone), so going to 1.5× and back is seamless.
    static var effectiveZoom: Double { isFlashlight ? 1 : zoomFactor }

    /// Only zooming above 1× needs Screen Recording; the flashlight works without it.
    static func requestScreenRecordingIfNeeded() {
        guard zoomOn else {
            return
        }
        askForScreenRecording()
    }

    /// Asks for Screen Recording: macOS's own prompt the first time, System Settings after that.
    static func askForScreenRecording() {
        guard !CGPreflightScreenCaptureAccess() else {
            return
        }
        // The first time, macOS's own prompt has the button to System Settings, so we don't open
        // them as well (that left the prompt standing over the hand after the relaunch). Once
        // macOS has asked, it stays quiet, so from then on we open System Settings ourselves.
        if !defaults.bool(forKey: "screenCaptureAsked") {
            set(true, "screenCaptureAsked")
            CGRequestScreenCaptureAccess()
            return
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    static let loupeSizeRange = 200...800

    /// Diameter of the zoom loupe in points.
    static var loupeSize: Int {
        get { min(800, max(200, defaults.object(forKey: "loupeSize") as? Int ?? 480)) }
        set { set(min(800, max(200, newValue)), "loupeSize") }
    }

    static let zoomFactorRange = 1.0...6.0

    static var zoomFactor: Double {
        get { min(6, max(1, defaults.object(forKey: "zoomFactor") as? Double ?? 1)) }
        set { set(min(6, max(1, newValue)), "zoomFactor") }
    }


    /// Resize the flashlight/loupe with up-and-down swipes (zoom then goes sideways).
    static var resizeVertically: Bool {
        get { defaults.object(forKey: "resizeVertically") as? Bool ?? true }
        set { set(newValue, "resizeVertically") }
    }

    /// Reverses scrolling with a mouse (not the trackpad): mouse software can set its own
    /// direction, apart from macOS's.
    static var reverseMouseScroll: Bool {
        get { defaults.object(forKey: "reverseMouseScroll") as? Bool ?? true }
        set { set(newValue, "reverseMouseScroll") }
    }

    /// Reverses both swipe directions (bigger and zoom in).
    static var reverseSwipe: Bool {
        get { defaults.object(forKey: "reverseSwipe") as? Bool ?? true }
        set { set(newValue, "reverseSwipe") }
    }

    static let dimAlphaRange = 0.1...0.9

    /// How dark the screen gets around the flashlight and the loupe, 10 % to 90 % black.
    static var dimAlpha: Double {
        get { min(0.9, max(0.1, defaults.object(forKey: "dimAlpha") as? Double ?? 0.5)) }
        set { set(min(0.9, max(0.1, newValue)), "dimAlpha") }
    }


    /// 1 to 40 pt (a line can't be 0 wide, so 1 is the thinnest).
    static let strokeSizeRange = 1...40

    /// Width of drawn lines in points.
    static var strokeSize: Int {
        get { min(40, max(1, defaults.object(forKey: "strokeSize") as? Int ?? 10)) }
        set { set(min(40, max(1, newValue)), "strokeSize") }
    }

    static let rainbowSpeedRange = 1...10

    /// How fast a rainbow line runs through the hues, 1 (slowest) to 10. At 5 a full cycle takes 8000 points of line.
    static var rainbowSpeed: Int {
        get { min(10, max(1, defaults.object(forKey: "rainbowSpeed") as? Int ?? 5)) }
        set { set(min(10, max(1, newValue)), "rainbowSpeed") }
    }

    /// Opacity of drawn lines in percent, 10 to 100, in steps of 10.
    static var inkOpacity: Int {
        get { min(100, max(10, defaults.object(forKey: "inkOpacity") as? Int ?? 80)) }
        set { set(min(100, max(10, newValue)), "inkOpacity") }
    }

    /// The opacity and size knobs in the toolbar.
    static var showKnobs: Bool {
        get { defaults.object(forKey: "showKnobs") as? Bool ?? false }
        set { set(newValue, "showKnobs") }
    }

    static var showInkButton: Bool {
        get { defaults.object(forKey: "showInkButton") as? Bool ?? true }
        set { set(newValue, "showInkButton") }
    }

    static let maxPinned = 8

    static var pinnedStyles: [PointerStyle] {
        get {
            guard let raw = defaults.stringArray(forKey: "pinnedStyles") else {
                return PointerStyle.defaultPinned
            }
            var seen = Set<PointerStyle>()
            let pinned = raw.compactMap(PointerStyle.init(rawValue:)).filter { seen.insert($0).inserted }
            return pinned.isEmpty ? PointerStyle.defaultPinned : pinned
        }
        set { set(newValue.map(\.rawValue), "pinnedStyles") }
    }

    static var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                Log.write("launch at login change failed: \(error.localizedDescription)")
            }
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// QuiteHandy was TinyHand (bundle com.kamranahmed.tinyhand). Copies its settings once,
    /// leaving out what belongs to that app alone (open-at-login setup, update checks).
    static func migrateFromTinyHand() {
        let flag = "migratedFromTinyHand"
        guard !defaults.bool(forKey: flag) else {
            return
        }
        defaults.set(true, forKey: flag)
        guard let old = defaults.persistentDomain(forName: "com.kamranahmed.tinyhand") else {
            return
        }
        var copied = 0
        for (key, value) in old where key != "loginItemSetUp" && !key.hasPrefix("SU") && defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
            copied += 1
        }
        Log.write("copied \(copied) settings from TinyHand")
    }

    static func resetAll() {
        for key in ["shortcut.toggle", "shortcut.clear", "shortcut.toolbar",
                    "shortcut.nextPointer", "shortcut.previousPointer", "shortcut.nextInk", "shortcut.previousInk", "shortcut.copyScreen", "shortcut.saveScreen", "shortcut.sound",
                    "shortcut.rainbowInk", "shortcut.matchInk", "shortcut.undo", "shortcut.redo", "pointerSize", "showShadow", "fadeSeconds",
                    "sound.hands", "sound.laser", "interactKey", "interactKeepsHand", "pinnedStyles", "pointerStyle",
                    "inkChoice", "showInkButton", "showKnobs", "tapSound", "showToolbar", "inkOpacity", "rainbowStep", "rainbowSpeed", "strokeSize",
                    "toolbarX", "toolbarY", "tapRipples", "soundOnDraw", "strokeSmoothing", "zoomKey", "loupeAdjustKey", "arrowKey", "stampKey", "loupeSize", "rightClickExits", "zoomFactor", "zoomOn", "dimAlpha", "resizeVertically", "reverseSwipe", "reverseMouseScroll", "zoomAnimated", "loupeDims", "showMenuBarIcon"] {
            defaults.removeObject(forKey: key)
        }
        NotificationCenter.default.post(name: changed, object: nil)
    }

        private static func set(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        // Size and zoom change in many small steps while you swipe: only Settings needs to know,
        // the rest of the app (toolbar, sounds, hand) would rebuild for nothing on every step.
        NotificationCenter.default.post(name: liveKeys.contains(key) ? liveChanged : changed, object: nil)
    }

    static let liveChanged = Notification.Name("QuiteHandyPreferencesLiveChanged")
    private static let liveKeys: Set<String> = ["loupeSize", "zoomFactor"]

    private static func loadShortcut(_ key: String) -> Shortcut? {
        guard let d = defaults.dictionary(forKey: key),
              let code = d["keyCode"] as? Int, let mods = d["modifiers"] as? Int, let label = d["display"] as? String else {
            return nil
        }
        return Shortcut(keyCode: UInt32(code), modifiers: UInt32(mods), display: label)
    }

    private static func saveShortcut(_ s: Shortcut, _ key: String) {
        set(["keyCode": Int(s.keyCode), "modifiers": Int(s.modifiers), "display": s.display], key)
    }
}
