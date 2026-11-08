import AppKit
import Carbon.HIToolbox
import ServiceManagement

struct Shortcut: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var display: String

    /// A shortcut without ⌃, ⌥ or ⌘, such as a lone ⇥. Only safe to grab while the pointer is on.
    var isBare: Bool { modifiers & UInt32(controlKey | optionKey | cmdKey) == 0 }

    static let toggleDefault = Shortcut(keyCode: UInt32(kVK_Tab), modifiers: UInt32(controlKey), display: "⌃⇥")
    static let clearDefault = Shortcut(keyCode: UInt32(kVK_Tab), modifiers: 0, display: "⇥")
    static let toolbarDefault = Shortcut(keyCode: UInt32(kVK_ANSI_T), modifiers: 0, display: "T")
}

enum InteractKey: String, CaseIterable {
    case option, command, control, off

    var title: String {
        switch self {
        case .option: return "⌥ Option"
        case .command: return "⌘ Command"
        case .control: return "⌃ Control"
        case .off: return "Off"
        }
    }

    var symbol: String {
        switch self {
        case .option: return "⌥"
        case .command: return "⌘"
        case .control: return "⌃"
        case .off: return ""
        }
    }

    var cgFlags: CGEventFlags {
        switch self {
        case .option: return .maskAlternate
        case .command: return .maskCommand
        case .control: return .maskControl
        case .off: return []
        }
    }
}

/// A modifier key that is held down, for example to zoom while it is pressed.
enum HoldKey: String, CaseIterable {
    case shift, control, option, command, off

    var title: String {
        switch self {
        case .shift: return "⇧ Shift"
        case .control: return "⌃ Control"
        case .option: return "⌥ Option"
        case .command: return "⌘ Command"
        case .off: return "Off"
        }
    }

    var cgFlags: CGEventFlags {
        switch self {
        case .shift: return .maskShift
        case .control: return .maskControl
        case .option: return .maskAlternate
        case .command: return .maskCommand
        case .off: return []
        }
    }
}

enum InkChoice: String, CaseIterable {
    case rainbow, match, red, orange, yellow, green, blue, purple, white, black

    var title: String {
        switch self {
        case .rainbow: return "Rainbow"
        case .match: return "Match the pointer"
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .blue: return "Blue"
        case .purple: return "Purple"
        case .white: return "White"
        case .black: return "Black"
        }
    }

    var color: CGColor? {
        switch self {
        case .rainbow, .match: return nil
        case .red: return Ink.red
        case .orange: return Ink.hex(0xFF8A00)
        case .yellow: return Ink.hex(0xFFCC00)
        case .green: return Ink.hex(0x30C25A)
        case .blue: return Ink.hex(0x0A84FF)
        case .purple: return Ink.hex(0x8754F2)
        case .white: return Ink.hex(0xFFFFFF)
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
    static let changed = Notification.Name("TinyPointerPreferencesChanged")
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

    static let pointerSizeRange: ClosedRange<CGFloat> = 0.08...0.20

    static var pointerSize: CGFloat {
        get { (defaults.object(forKey: "pointerSize") as? Double).map { CGFloat($0) } ?? 0.13 }
        set { set(Double(newValue), "pointerSize") }
    }

    static var showShadow: Bool {
        get { defaults.object(forKey: "showShadow") as? Bool ?? true }
        set { set(newValue, "showShadow") }
    }

    static var fadeSeconds: Double {
        get { defaults.object(forKey: "fadeSeconds") as? Double ?? 3 }
        set { set(newValue, "fadeSeconds") }
    }

    static var handSound: Bool {
        get { defaults.object(forKey: "sound.hands") as? Bool ?? true }
        set { set(newValue, "sound.hands") }
    }

    static var tapSound: TapSoundChoice {
        get { defaults.string(forKey: "tapSound").flatMap(TapSoundChoice.init(rawValue:)) ?? .thock }
        set { set(newValue.rawValue, "tapSound") }
    }

    static var laserSound: Bool {
        get { defaults.object(forKey: "sound.laser") as? Bool ?? false }
        set { set(newValue, "sound.laser") }
    }

    static var interactKeepsHand: Bool {
        get { defaults.bool(forKey: "interactKeepsHand") }
        set { set(newValue, "interactKeepsHand") }
    }

    static var interactKey: InteractKey {
        get { defaults.string(forKey: "interactKey").flatMap(InteractKey.init(rawValue:)) ?? .control }
        set { set(newValue.rawValue, "interactKey") }
    }

    static var inkChoice: InkChoice {
        get { defaults.string(forKey: "inkChoice").flatMap(InkChoice.init(rawValue:)) ?? .match }
        set { set(newValue.rawValue, "inkChoice") }
    }

    static var showToolbar: Bool {
        get { defaults.object(forKey: "showToolbar") as? Bool ?? true }
        set { set(newValue, "showToolbar") }
    }

    static let rainbowStepChoices = Array(stride(from: 0, through: 90, by: 10))

    /// How many degrees of hue each new rainbow line starts further along, until the drawing is cleared.
    static var rainbowStep: Int {
        get { min(90, max(0, defaults.object(forKey: "rainbowStep") as? Int ?? 60)) }
        set { set(min(90, max(0, newValue)), "rainbowStep") }
    }

    /// A right click turns the pointer off, like Esc.
    static var rightClickExits: Bool {
        get { defaults.bool(forKey: "rightClickExits") }
        set { set(newValue, "rightClickExits") }
    }

    static var zoomKey: HoldKey {
        get { defaults.string(forKey: "zoomKey").flatMap(HoldKey.init(rawValue:)) ?? .shift }
        set { set(newValue.rawValue, "zoomKey") }
    }

    static let loupeSizeRange = 120...480

    /// Diameter of the zoom loupe in points.
    static var loupeSize: Int {
        get { min(480, max(120, defaults.object(forKey: "loupeSize") as? Int ?? 240)) }
        set { set(min(480, max(120, newValue)), "loupeSize") }
    }

    static let zoomFactorChoices: [Double] = [1.5, 2, 2.5, 3, 4, 5, 6]

    static var zoomFactor: Double {
        get { defaults.object(forKey: "zoomFactor") as? Double ?? 3 }
        set { set(newValue, "zoomFactor") }
    }

    /// Zoom in and out smoothly instead of jumping straight to the factor.
    static var zoomAnimated: Bool {
        get { defaults.object(forKey: "zoomAnimated") as? Bool ?? true }
        set { set(newValue, "zoomAnimated") }
    }

    static let strokeSizeRange = 2...20

    /// Width of drawn lines in points.
    static var strokeSize: Int {
        get { min(20, max(2, defaults.object(forKey: "strokeSize") as? Int ?? 6)) }
        set { set(min(20, max(2, newValue)), "strokeSize") }
    }

    static let rainbowSpeedRange = 1...10

    /// How fast a rainbow line runs through the hues, 1 (slowest) to 10. At 5 a full cycle takes 8000 points of line.
    static var rainbowSpeed: Int {
        get { min(10, max(1, defaults.object(forKey: "rainbowSpeed") as? Int ?? 5)) }
        set { set(min(10, max(1, newValue)), "rainbowSpeed") }
    }

    /// Opacity of drawn lines in percent, 10 to 100, in steps of 10.
    static var inkOpacity: Int {
        get { min(100, max(10, defaults.object(forKey: "inkOpacity") as? Int ?? 100)) }
        set { set(min(100, max(10, newValue)), "inkOpacity") }
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

    /// TinyPointer was TinyHand (bundle com.kamranahmed.tinyhand). Copies its settings once,
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
        for key in ["shortcut.toggle", "shortcut.clear", "shortcut.toolbar", "pointerSize", "showShadow", "fadeSeconds",
                    "sound.hands", "sound.laser", "interactKey", "interactKeepsHand", "pinnedStyles", "pointerStyle",
                    "inkChoice", "showInkButton", "tapSound", "showToolbar", "inkOpacity", "rainbowStep", "rainbowSpeed", "strokeSize",
                    "zoomKey", "loupeSize", "rightClickExits", "zoomFactor", "zoomAnimated"] {
            defaults.removeObject(forKey: key)
        }
        NotificationCenter.default.post(name: changed, object: nil)
    }

        private static func set(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: changed, object: nil)
    }

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
