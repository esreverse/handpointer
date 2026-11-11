import AppKit
import ApplicationServices
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, shortcuts, toolbar, drawing, zoom, pointers, sound, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .pointers: return "Pointers"
        case .shortcuts: return "Shortcuts"
        case .toolbar: return "Interface"
        case .drawing: return "Draw"
        case .zoom: return "Flashlight"
        case .sound: return "Sound"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .pointers: return "hand.point.up.left.fill"
        case .shortcuts: return "keyboard"
        case .toolbar: return "menubar.dock.rectangle"
        case .drawing: return "pencil.tip"
        case .zoom: return "plus.magnifyingglass"
        case .sound: return "speaker.wave.2.fill"
        case .about: return "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: return Color(white: 0.55)
        case .pointers: return Color(red: 0.55, green: 0.42, blue: 0.95)
        case .shortcuts: return Color(red: 0.36, green: 0.4, blue: 0.9)
        case .toolbar: return Color(red: 0.45, green: 0.52, blue: 0.6)
        case .drawing: return Color(red: 0.96, green: 0.58, blue: 0.2)
        case .zoom: return Color(red: 0.2, green: 0.72, blue: 0.68)
        case .sound: return Color(red: 0.2, green: 0.55, blue: 0.98)
        case .about: return Color(white: 0.45)
        }
    }
}

final class SettingsModel: ObservableObject {
    @Published var section: SettingsSection = .general
    @Published var pinMessage: String?
    @Published private var revision = 0

    var applyToggleShortcut: ((Shortcut) -> Bool)?
    var applyClearShortcut: ((Shortcut) -> Bool)?
    var applyToolbarShortcut: ((Shortcut) -> Bool)?
    var applyRainbowInkShortcut: ((Shortcut) -> Bool)?
    var applyMatchInkShortcut: ((Shortcut) -> Bool)?
    var applyNextPointerShortcut: ((Shortcut) -> Bool)?
    var applyNextInkShortcut: ((Shortcut) -> Bool)?
    var applyCopyScreenShortcut: ((Shortcut) -> Bool)?
    var applySaveScreenShortcut: ((Shortcut) -> Bool)?
    var applyPreviousInkShortcut: ((Shortcut) -> Bool)?
    var applyPreviousPointerShortcut: ((Shortcut) -> Bool)?
    var applySoundShortcut: ((Shortcut) -> Bool)?
    var applyUndoShortcut: ((Shortcut) -> Bool)?
    var applyRedoShortcut: ((Shortcut) -> Bool)?
    var updater: Updater?
    var onRecording: ((Bool) -> Void)?
    @Published var shortcutError: String?

    private var observer: Any?
    private var handsObserver: Any?
    private var liveObserver: Any?
    @Published var handMessage: String?

    init() {
        observer = NotificationCenter.default.addObserver(forName: Preferences.changed, object: nil, queue: .main) { [weak self] _ in
            self?.revision += 1
        }
        liveObserver = NotificationCenter.default.addObserver(forName: Preferences.liveChanged, object: nil, queue: .main) { [weak self] _ in
            self?.revision += 1
        }
        handsObserver = NotificationCenter.default.addObserver(forName: CustomHands.changed, object: nil, queue: .main) { [weak self] _ in
            self?.revision += 1
        }
        HandAsset.preloadThumbnails(PointerStyle.allCases.compactMap(\.assetName)) { [weak self] in
            self?.revision += 1
        }
    }

    struct HandDraft {
        let image: CGImage
        let ink: UInt32
    }

    @Published var makingHand = false
    @Published var handIdea = ""
    @Published var handName = ""
    @Published var draft: HandDraft?
    @Published var draftError: String?
    @Published var promptCopied = false

    func startMakingHand() {
        draft = nil
        draftError = nil
        promptCopied = false
        handMessage = nil
        makingHand = true
    }

    private var copiedReset: DispatchWorkItem?

    func copyPrompt() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(HandMaker.prompt(for: handIdea), forType: .string)
        promptCopied = true
        copiedReset?.cancel()
        let reset = DispatchWorkItem { [weak self] in self?.promptCopied = false }
        copiedReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: reset)
    }

    func openChatGPT() {
        var parts = URLComponents(string: "https://chatgpt.com/")
        parts?.queryItems = [URLQueryItem(name: "q", value: HandMaker.prompt(for: handIdea))]
        if let url = parts?.url {
            NSWorkspace.shared.open(url)
        }
    }

    func chooseHandFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .webP, .image]
        panel.allowsMultipleSelection = false
        panel.message = "Pick the PNG of your hand"
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        loadDraft(url)
    }

    func loadDraft(_ url: URL) {
        do {
            let made = try HandMaker.make(from: url)
            draft = HandDraft(image: made.image, ink: made.ink)
            draftError = nil
            handName = CustomHands.suggestedName(for: url)
        } catch let problem as HandMaker.Problem {
            draft = nil
            draftError = problem.message
        } catch {
            draft = nil
            draftError = "Quite Handy couldn't read that file."
        }
    }

    func saveDraft() {
        guard let draft = draft else {
            return
        }
        do {
            let style = try CustomHands.add(draft.image, ink: draft.ink, name: handName)
            if let name = style.assetName {
                _ = HandAsset.thumbnail(name)
            }
            var pinned = Preferences.pinnedStyles
            if pinned.count < Preferences.maxPinned {
                pinned.append(style)
                Preferences.pinnedStyles = pinned
                handMessage = "\(style.title) is in your toolbar."
            } else {
                handMessage = "\(style.title) is ready. Click it to add it to the toolbar."
            }
            PointerStyle.saved = style
            NotificationCenter.default.post(name: Preferences.changed, object: nil)
            self.draft = nil
            handIdea = ""
            makingHand = false
        } catch {
            draftError = "Quite Handy couldn't save that hand."
        }
    }

    func removeHand(_ style: PointerStyle) {
        let pinned = Preferences.pinnedStyles.filter { $0 != style }
        Preferences.pinnedStyles = pinned.isEmpty ? PointerStyle.defaultPinned : pinned
        if PointerStyle.saved == style {
            PointerStyle.saved = .lavender
        }
        CustomHands.remove(style)
        handMessage = nil
        NotificationCenter.default.post(name: Preferences.changed, object: nil)
        revision += 1
    }

    func refresh() {
        revision += 1
    }

    func binding<T>(_ get: @escaping () -> T, _ set: @escaping (T) -> Void) -> Binding<T> {
        Binding(get: get, set: { value in
            set(value)
            self.revision += 1
        })
    }

    private var previewSound: TapSound?

    func warmPreview() {
        if previewSound == nil {
            previewSound = TapSound()
        }
        previewSound?.warm()
    }

    func preview(_ choice: TapSoundChoice) {
        if previewSound == nil {
            previewSound = TapSound(choice)
        }
        previewSound?.load(choice)
        previewSound?.play()
    }

    @Published var dragging: PointerStyle?
    @Published private var draftOrder: [PointerStyle]?

    var pinnedOrder: [PointerStyle] {
        draftOrder ?? Preferences.pinnedStyles
    }

    private(set) var baseOrder: [PointerStyle] = []

    func beginDrag(_ style: PointerStyle) {
        dragging = style
        baseOrder = Preferences.pinnedStyles
        draftOrder = baseOrder
        pinMessage = nil
    }

    func setDraft(_ order: [PointerStyle]) {
        guard order != draftOrder else {
            return
        }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            draftOrder = order
        }
    }

    func cancelDrag() {
        draftOrder = nil
        dragging = nil
    }

    func resetToolbar() {
        pinMessage = nil
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            Preferences.pinnedStyles = PointerStyle.defaultPinned
        }
    }

    func resetAll() {
        let alert = NSAlert()
        alert.messageText = "Reset all settings?"
        alert.informativeText = "Shortcuts, toolbar pointers, size, shadow, drawing and sound go back to how they were at first. Open at login and Accessibility stay as they are."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }
        Preferences.resetAll()
        _ = applyToggleShortcut?(.toggleDefault)
        _ = applyClearShortcut?(.clearDefault)
        _ = applyToolbarShortcut?(.toolbarDefault)
        _ = applyRainbowInkShortcut?(.rainbowInkDefault)
        _ = applyMatchInkShortcut?(.matchInkDefault)
        _ = applyNextPointerShortcut?(.nextPointerDefault)
        _ = applyNextInkShortcut?(.nextInkDefault)
        _ = applyCopyScreenShortcut?(.copyScreenDefault)
        _ = applySaveScreenShortcut?(.saveScreenDefault)
        _ = applyPreviousInkShortcut?(.previousInkDefault)
        _ = applyPreviousPointerShortcut?(.previousPointerDefault)
        _ = applySoundShortcut?(.soundDefault)
        _ = applyUndoShortcut?(.undoDefault)
        _ = applyRedoShortcut?(.redoDefault)
        shortcutError = nil
        pinMessage = nil
        revision += 1
    }

    func endDrag() {
        if let order = draftOrder {
            Preferences.pinnedStyles = order
        }
        draftOrder = nil
        dragging = nil
    }

    func pin(_ style: PointerStyle) {
        var pinned = Preferences.pinnedStyles
        if pinned.contains(style) {
            unpin(style)
            return
        }
        if pinned.count >= Preferences.maxPinned {
            pinMessage = "The toolbar is full. Remove one above to add \(style.title)."
            return
        }
        pinned.append(style)
        pinMessage = nil
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            Preferences.pinnedStyles = pinned
        }
    }

    func swap(_ old: PointerStyle, for new: PointerStyle) {
        var pinned = Preferences.pinnedStyles
        guard let i = pinned.firstIndex(of: old), !pinned.contains(new) else {
            return
        }
        pinned[i] = new
        pinMessage = nil
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            Preferences.pinnedStyles = pinned
        }
    }

    func unpin(_ style: PointerStyle) {
        var pinned = Preferences.pinnedStyles
        guard let i = pinned.firstIndex(of: style) else {
            return
        }
        if pinned.count == 1 {
            pinMessage = "Keep at least one pointer in the toolbar."
            return
        }
        pinned.remove(at: i)
        pinMessage = nil
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            Preferences.pinnedStyles = pinned
        }
    }

}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            page
        }
        .ignoresSafeArea()
        .frame(minWidth: 760, minHeight: 540)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsSection.allCases.filter { $0 != .about }) { section in
                SidebarRow(section: section, selected: model.section == section) {
                    model.section = section
                }
            }
            Spacer()
            // About sits at the bottom, apart from the settings.
            SidebarRow(section: .about, selected: model.section == .about) {
                model.section = .about
            }
            .padding(.bottom, 12)
        }
        .padding(.top, 52)
        .padding(.horizontal, 10)
        .frame(width: 210)
        .frame(maxHeight: .infinity)
        .background(VisualEffect(material: .sidebar))
    }

    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if model.section == .pointers && model.makingHand {
                    Button {
                        model.makingHand = false
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                            Text("Pointers").font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .padding(.bottom, -14)
                }
                Text(model.section == .pointers && model.makingHand ? "Make your own hand" : model.section.title)
                    .font(.system(size: 22, weight: .bold))
                    .padding(.top, 6)
                content
            }
            // Always lay the page out at its natural height, so rows keep the same spacing
            // whether or not the page is taller than the window.
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 28)
            .padding(.top, 48)
            .padding(.bottom, 56)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var content: some View {
        switch model.section {
        case .general: GeneralPage(model: model)
        case .shortcuts: ShortcutsPage(model: model)
        case .pointers:
            if model.makingHand {
                MakeHandPage(model: model)
            } else {
                PointersPage(model: model)
            }
        case .toolbar: ToolbarPage(model: model)
        case .drawing: DrawingPage(model: model)
        case .zoom: ZoomPage(model: model)
        case .sound: SoundPage(model: model)
        case .about: AboutPage(model: model)
        }
    }
}

private struct GeneralPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Card(title: "Startup") {
                Row("Open Quite Handy when you log in") {
                    Toggle("", isOn: model.binding({ Preferences.launchAtLogin }, { Preferences.launchAtLogin = $0 }))
                        .toggleStyle(.switch).labelsHidden().focusable(false)
                }
                Row("Show icon in menu bar", detail: "Press ⌘, while Quite Handy is active to open Settings") {
                    Toggle("", isOn: model.binding({ Preferences.showMenuBarIcon }, { Preferences.showMenuBarIcon = $0 }))
                        .toggleStyle(.switch).labelsHidden().focusable(false)
                }
            }
            if let updater = model.updater {
                Card(title: "Updates") {
                    Row("Update automatically", detail: "Checks GitHub for new versions and installs them") {
                        Toggle("", isOn: model.binding({ updater.autoUpdate }, { updater.autoUpdate = $0 }))
                            .toggleStyle(.switch).labelsHidden().focusable(false)
                    }
                    Row("Check for updates", detail: GeneralPage.updateDetail(updater)) {
                        PillButton(title: "Check Now") { updater.checkForUpdates() }
                    }
                }
            }
            Card(title: "Permissions") {
                Row("Accessibility", detail: "Needed for the pointer: Clicks become taps and you can draw", allowed: Permissions.accessibility) {
                    PillButton(title: "Open Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                Row("Screen Recording", detail: "Only needed for zoom, the flashlight works without it", allowed: Permissions.screenRecording) {
                    PillButton(title: "Open Settings") {
                        Preferences.askForScreenRecording()
                    }
                }
            }
        }
    }
}

extension GeneralPage {
    static func updateDetail(_ updater: Updater) -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        guard let date = updater.lastCheck else {
            return "Version \(version)"
        }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return "Version \(version), last checked \(f.string(from: date))"
    }
}

/// Permission state for the settings pages. TH_SCREENSHOT=1 shows both as allowed,
/// for README screenshots rendered with --settings-test.
private enum Permissions {
    static var screenshot: Bool { ProcessInfo.processInfo.environment["TH_SCREENSHOT"] != nil }
    static var accessibility: Bool { screenshot || AXIsProcessTrusted() }
    static var screenRecording: Bool { screenshot || CGPreflightScreenCaptureAccess() }
}

private struct ShortcutsPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Card(title: "On/Off") {
                Row("Toggle on/off", conflict: Conflicts.shortcut(Preferences.toggleShortcut)) {
                    ShortcutField(shortcut: Preferences.toggleShortcut, model: model) { model.applyToggleShortcut?($0) ?? false }
                }
                Row("Show/hide toolbar", detail: "Shows or hides the bar with the pointers at the bottom of the screen", conflict: Conflicts.shortcut(Preferences.toolbarShortcut)) {
                    ShortcutField(shortcut: Preferences.toolbarShortcut, model: model, allowsBareKey: true) { model.applyToolbarShortcut?($0) ?? false }
                }
                Row("Right-click ends session", detail: "Like Esc: Clears the drawing and ends the session") {
                    Toggle("", isOn: model.binding({ Preferences.rightClickExits }, { Preferences.rightClickExits = $0 }))
                        .toggleStyle(.switch).labelsHidden().focusable(false)
                }
            }
            Card(title: "Draw") {
                Row("Clear drawing", detail: "Removes all lines and stamps, Quite Handy stays active", conflict: Conflicts.shortcut(Preferences.clearShortcut)) {
                    ShortcutField(shortcut: Preferences.clearShortcut, model: model, allowsBareKey: true) { model.applyClearShortcut?($0) ?? false }
                }
                Row("Undo", detail: "Takes back the last action – hold to keep going", conflict: Conflicts.shortcut(Preferences.undoShortcut)) {
                    ShortcutField(shortcut: Preferences.undoShortcut, model: model, allowsBareKey: true) { model.applyUndoShortcut?($0) ?? false }
                }
                Row("Redo", detail: "Brings back what you took back – hold to keep going", conflict: Conflicts.shortcut(Preferences.redoShortcut)) {
                    ShortcutField(shortcut: Preferences.redoShortcut, model: model, allowsBareKey: true) { model.applyRedoShortcut?($0) ?? false }
                }
                Row("Use next pointer", detail: "Goes through the pointers in your toolbar – hold to keep going", conflict: Conflicts.shortcut(Preferences.nextPointerShortcut)) {
                    ShortcutField(shortcut: Preferences.nextPointerShortcut, model: model, allowsBareKey: true) { model.applyNextPointerShortcut?($0) ?? false }
                }
                Row("Use previous pointer", detail: "Goes back through the pointers in your toolbar – hold to keep going", conflict: Conflicts.shortcut(Preferences.previousPointerShortcut)) {
                    ShortcutField(shortcut: Preferences.previousPointerShortcut, model: model, allowsBareKey: true) { model.applyPreviousPointerShortcut?($0) ?? false }
                }
                Row("Use next colour", detail: "Goes through the ink colours – hold to keep going", conflict: Conflicts.shortcut(Preferences.nextInkShortcut)) {
                    ShortcutField(shortcut: Preferences.nextInkShortcut, model: model, allowsBareKey: true) { model.applyNextInkShortcut?($0) ?? false }
                }
                Row("Use previous colour", detail: "Goes back through the ink colours – hold to keep going", conflict: Conflicts.shortcut(Preferences.previousInkShortcut)) {
                    ShortcutField(shortcut: Preferences.previousInkShortcut, model: model, allowsBareKey: true) { model.applyPreviousInkShortcut?($0) ?? false }
                }
                Row("Use rainbow colour", detail: "Draws in all colours of the rainbow", conflict: Conflicts.shortcut(Preferences.rainbowInkShortcut)) {
                    ShortcutField(shortcut: Preferences.rainbowInkShortcut, model: model, allowsBareKey: true) { model.applyRainbowInkShortcut?($0) ?? false }
                }
                Row("Use automatic colour", detail: "Matches each pointer", conflict: Conflicts.shortcut(Preferences.matchInkShortcut)) {
                    ShortcutField(shortcut: Preferences.matchInkShortcut, model: model, allowsBareKey: true) { model.applyMatchInkShortcut?($0) ?? false }
                }
                Row("Hold to stamp numbers", detail: "Hold the key and click to place 1 to 9, keep holding to make it bigger. Drag to move, click to remove, press 1 to 9 on the keyboard over a stamp to change its number", conflict: Conflicts.hold(Preferences.stampKey.cgFlags)) {
                    Picker("", selection: model.binding({ Preferences.stampKey }, { Preferences.stampKey = $0 })) {
                        ForEach(HoldKey.allCases, id: \.self) { key in
                            Text(key.title).tag(key)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    // White pop-up without the blue accent on its arrows (where macOS lets us).
                    .tint(Color(white: 0.55))
                    .fixedSize()
                    .focusable(false)
                }
            }
            Card(title: "Screenshot") {
                Row("Copy screenshot", conflict: Conflicts.shortcut(Preferences.copyScreenShortcut)) {
                    ShortcutField(shortcut: Preferences.copyScreenShortcut, model: model) { model.applyCopyScreenShortcut?($0) ?? false }
                }
                Row("Save screenshot to desktop", conflict: Conflicts.shortcut(Preferences.saveScreenShortcut)) {
                    ShortcutField(shortcut: Preferences.saveScreenShortcut, model: model) { model.applySaveScreenShortcut?($0) ?? false }
                }
            }
            Card(title: "Flashlight") {
                Row("Hold for flashlight", detail: DrawingPage.zoomKeyDetail, conflict: Conflicts.hold(Preferences.zoomKey.cgFlags)) {
                    Picker("", selection: model.binding({ Preferences.zoomKey }, { key in
                        Preferences.zoomKey = key
                        if key != .off {
                            Preferences.requestScreenRecordingIfNeeded()
                        }
                    })) {
                        ForEach(HoldKey.allCases.filter { $0 != .off }, id: \.self) { key in
                            Text(key.title).tag(key)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    // White pop-up without the blue accent on its arrows (where macOS lets us).
                    .tint(Color(white: 0.55))
                    .fixedSize()
                    .focusable(false)
                }
                Row("Hold to change size and zoom factor", detail: "Hold the key while the flashlight is on and move the mouse (alternative to swiping on the trackpad)", conflict: Conflicts.hold(Preferences.loupeAdjustKey.cgFlags)) {
                    Picker("", selection: model.binding({ Preferences.loupeAdjustKey }, { Preferences.loupeAdjustKey = $0 })) {
                        ForEach(HoldKey.allCases, id: \.self) { key in
                            Text(key.title).tag(key)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    // White pop-up without the blue accent on its arrows (where macOS lets us).
                    .tint(Color(white: 0.55))
                    .fixedSize()
                    .focusable(false)
                }
            }
            Card(title: "Clicking") {
                Row("Hold to interact with your Mac", detail: "Clicks, drags and scrolls reach your Mac", conflict: Conflicts.hold(Preferences.interactKey.cgFlags)) {
                    Picker("", selection: model.binding({ Preferences.interactKey }, { Preferences.interactKey = $0 })) {
                        ForEach(InteractKey.allCases, id: \.self) { key in
                            Text(key.title).tag(key)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    // White pop-up without the blue accent on its arrows (where macOS lets us).
                    .tint(Color(white: 0.55))
                    .fixedSize()
                    .focusable(false)
                }
                if Preferences.interactKey != .off {
                    Row("While holding", detail: Preferences.interactKeepsHand ? "The hand stays" : "The normal cursor comes back") {
                        Picker("", selection: model.binding({ Preferences.interactKeepsHand }, { Preferences.interactKeepsHand = $0 })) {
                            Text("Show cursor").tag(false)
                            Text("Keep hand").tag(true)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    // White pop-up without the blue accent on its arrows (where macOS lets us).
                    .tint(Color(white: 0.55))
                        .fixedSize()
                        .focusable(false)
                    }
                }
            }
            Card(title: "Sound") {
                Row("Toggle sound on/off", conflict: Conflicts.shortcut(Preferences.soundShortcut)) {
                    ShortcutField(shortcut: Preferences.soundShortcut, model: model, allowsBareKey: true) { model.applySoundShortcut?($0) ?? false }
                }
            }
            if let error = model.shortcutError {
                Text(error).font(.system(size: 12)).foregroundColor(.red)
            }
        }
    }
}

private struct PointersPage: View {
    @ObservedObject var model: SettingsModel
    @State private var rowFrame: CGRect = .zero
    @State private var dragX: CGFloat = 0
    @State private var dragStart = 0
    @State private var floating: Floating?
    @State private var picking = false

    struct Floating {
        let style: PointerStyle
        let point: CGPoint
        let badge: String?
    }

    private var step: CGFloat {
        (rowFrame.width - 20 + 6) / CGFloat(Preferences.maxPinned)
    }

    private func overRow(_ p: CGPoint) -> Bool {
        rowFrame.insetBy(dx: -16, dy: -28).contains(p)
    }

    private func slot(at x: CGFloat, count: Int) -> Int {
        min(max(Int((x - rowFrame.minX - 10) / step), 0), max(0, count - 1))
    }

    private func rowDrag(_ value: DragGesture.Value) {
        let start = CGPoint(x: rowFrame.minX + value.startLocation.x, y: rowFrame.minY + value.startLocation.y)
        let p = CGPoint(x: rowFrame.minX + value.location.x, y: rowFrame.minY + value.location.y)
        if model.dragging == nil {
            let base = Preferences.pinnedStyles
            let i = Int((start.x - rowFrame.minX - 10) / step)
            guard start.x >= rowFrame.minX + 10, base.indices.contains(i) else {
                return
            }
            dragStart = i
            model.beginDrag(base[i])
        }
        guard let style = model.dragging else {
            return
        }
        var order = model.baseOrder.filter { $0 != style }
        if overRow(p) {
            dragX = value.translation.width
            order.insert(style, at: slot(at: p.x, count: order.count + 1))
            floating = nil
        } else if model.baseOrder.count > 1 {
            floating = Floating(style: style, point: p, badge: "minus.circle.fill")
        } else {
            order = model.baseOrder
            floating = Floating(style: style, point: p, badge: nil)
        }
        model.setDraft(order)
    }

    private func dropDrag() {
        let removing = floating?.badge == "minus.circle.fill"
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            dragX = 0
            if floating != nil && !removing {
                model.cancelDrag()
                model.pinMessage = "Keep at least one pointer in the toolbar."
            } else {
                model.endDrag()
            }
            floating = nil
        }
    }

    private func offset(_ style: PointerStyle) -> CGFloat {
        guard model.dragging == style, floating == nil, let i = model.pinnedOrder.firstIndex(of: style) else {
            return 0
        }
        return dragX - CGFloat(i - dragStart) * step
    }

    var body: some View {
        let pinned = model.pinnedOrder
        let full = Preferences.pinnedStyles.count >= Preferences.maxPinned
        VStack(alignment: .leading, spacing: 30) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("In your toolbar")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    TextButton(title: "Reset") { model.resetToolbar() }
                }
                .padding(.horizontal, 4)
                HStack(spacing: 6) {
                    ForEach(pinned, id: \.self) { style in
                        let lifted = model.dragging == style
                        ToolbarSlot(style: style, model: model, lifted: lifted)
                            .offset(x: offset(style))
                            .zIndex(lifted ? 1 : 0)
                            .transaction { if lifted { $0.animation = nil } }
                    }
                    if !full {
                        AddSlot(open: $picking)
                            .popover(isPresented: $picking, arrowEdge: .bottom) {
                                PointerPicker(model: model) { picking = false }
                            }
                    }
                    ForEach(0..<max(0, Preferences.maxPinned - pinned.count - 1), id: \.self) { _ in
                        EmptySlot()
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.primary.opacity(0.045))
                )
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { rowFrame = g.frame(in: .named("pointersPage")) }
                        .onChange(of: g.frame(in: .named("pointersPage"))) { rowFrame = $0 }
                })
                .coordinateSpace(name: "toolbarRow")
                .gesture(
                    DragGesture(minimumDistance: 3, coordinateSpace: .named("toolbarRow"))
                        .onChanged { rowDrag($0) }
                        .onEnded { _ in dropDrag() }
                )
                Text(full
                     ? "The toolbar is full. Remove a pointer to add another. Drag to reorder."
                     : "Press + to add a pointer. Drag to reorder, or out to remove.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
                if let message = model.pinMessage {
                    Text(message).font(.system(size: 12)).foregroundColor(.red).padding(.horizontal, 4)
                }
            }
            YourHands(model: model)
        }
        .coordinateSpace(name: "pointersPage")
        .overlay(alignment: .topLeading) {
            if let f = floating {
                FloatingPointer(style: f.style, badge: f.badge)
                    .position(f.point)
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct AddSlot: View {
    @Binding var open: Bool
    @State private var hovering = false

    var body: some View {
        Button {
            open.toggle()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(hovering || open ? .primary : .secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 58)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(hovering || open ? 0.09 : 0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help("Add a pointer")
        .onHover { hovering = $0 }
    }
}

private struct PointerPicker: View {
    @ObservedObject var model: SettingsModel
    let done: () -> Void
    private let columns = [GridItem(.adaptive(minimum: 64, maximum: 72), spacing: 4)]

    var body: some View {
        let pinned = Set(Preferences.pinnedStyles)
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    section(nil, PointerStyle.builtInHands, pinned)
                    if !PointerStyle.customHands.isEmpty {
                        section("Your hands", PointerStyle.customHands, pinned)
                    }
                }
                .padding(12)
            }
            .frame(height: 340)
            Divider()
            Button {
                done()
                model.startMakingHand()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars").font(.system(size: 11))
                    Text("Make your own hand").font(.system(size: 12))
                    Spacer()
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
        }
        .frame(width: 400)
    }

    private func section(_ title: String?, _ styles: [PointerStyle], _ pinned: Set<PointerStyle>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = title {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary).padding(.leading, 4)
            }
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(styles, id: \.self) { style in
                    PickerCell(style: style, added: pinned.contains(style)) {
                        guard !pinned.contains(style) else {
                            return
                        }
                        model.pin(style)
                        done()
                    }
                }
            }
        }
    }
}

private struct PickerCell: View {
    let style: PointerStyle
    let added: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if let icon = pointerIcon(style) {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 42, height: 42)
                }
            }
            .frame(width: 62, height: 58)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    // Same as the toolbar: in the toolbar 20 %, hover 10 %.
                    .fill(Color.primary.opacity(added ? 0.2 : (hovering ? 0.1 : 0)))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(added ? "\(style.title) is already in the toolbar" : style.title)
        .onHover { hovering = $0 }
    }
}

private struct YourHands: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your hands")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                TextButton(title: "Make your own") { model.startMakingHand() }
            }
            .padding(.horizontal, 4)
            if PointerStyle.customHands.isEmpty {
                Text("Turn any idea into a hand with ChatGPT or another image tool")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
            } else {
                HStack(spacing: 6) {
                    ForEach(PointerStyle.customHands, id: \.self) { style in
                        CustomHandChip(style: style, model: model)
                    }
                }
            }
            if let message = model.handMessage {
                Text(message).font(.system(size: 11)).foregroundColor(.secondary).padding(.horizontal, 4)
            }
        }
    }
}

private struct CustomHandChip: View {
    let style: PointerStyle
    @ObservedObject var model: SettingsModel
    @State private var hovering = false
    @State private var swapping = false

    var body: some View {
        let pinned = Preferences.pinnedStyles.contains(style)
        let full = Preferences.pinnedStyles.count >= Preferences.maxPinned
        HStack(spacing: 6) {
            if let icon = pointerIcon(style) {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: 24, height: 24)
            }
            Text(style.title).font(.system(size: 12)).lineLimit(1)
            Button {
                model.removeHand(style)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.secondary)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Color.primary.opacity(hovering ? 0.12 : 0)))
            }
            .buttonStyle(.plain)
            .focusable(false)
            .opacity(hovering ? 1 : 0)
            .help("Delete \(style.title)")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.primary.opacity(hovering && !pinned ? 0.09 : 0.05)))
        .contentShape(Capsule())
        .onTapGesture {
            guard !pinned else {
                return
            }
            if full {
                swapping = true
            } else {
                model.pin(style)
            }
        }
        .onHover { hovering = $0 }
        .help(pinned ? "\(style.title) is in your toolbar" : "Click to add \(style.title) to the toolbar")
        .popover(isPresented: $swapping, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("The toolbar is full. Swap \(style.title) in for:")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                HStack(spacing: 4) {
                    ForEach(Preferences.pinnedStyles, id: \.self) { old in
                        SwapCell(style: old) {
                            model.swap(old, for: style)
                            swapping = false
                        }
                    }
                }
            }
            .padding(12)
        }
    }
}

private struct SwapCell: View {
    let style: PointerStyle
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if let icon = pointerIcon(style) {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 32, height: 32)
                }
            }
            .frame(width: 44, height: 44)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(hovering ? 0.1 : 0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help("Replace \(style.title)")
        .onHover { hovering = $0 }
    }
}
private struct FloatingPointer: View {
    let style: PointerStyle
    let badge: String?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let icon = pointerIcon(style) {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 40, height: 40)
                }
            }
            .frame(width: 58, height: 58)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.95))
                    .shadow(color: .black.opacity(0.25), radius: 12, y: 5)
            )
            if let badge = badge {
                Image(systemName: badge)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white, badge == "nosign" ? Color.gray : Color.red)
                    .offset(x: 6, y: -6)
            }
        }
        .scaleEffect(1.06)
    }
}

private struct ToolbarSlot: View {
    let style: PointerStyle
    @ObservedObject var model: SettingsModel
    let lifted: Bool
    @State private var hovering = false

    var body: some View {
        slot
    }

    private var slot: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let icon = pointerIcon(style) {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 40, height: 40)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.95))
                    .shadow(color: .black.opacity(lifted ? 0.22 : 0.08), radius: lifted ? 10 : 2, y: lifted ? 4 : 1)
            )
            .scaleEffect(lifted ? 1.06 : 1)
            if hovering && model.dragging == nil {
                Button {
                    model.unpin(style)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Remove from the toolbar")
                .offset(x: 5, y: -5)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(style.title)
    }
}

private struct EmptySlot: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.primary.opacity(0.035))
            .frame(maxWidth: .infinity)
            .frame(height: 58)
    }
}

private struct DrawingPage: View {
    static var zoomKeyDetail: String {
        let key = Preferences.zoomKey
        if key != .off && key.cgFlags == Preferences.interactKey.cgFlags {
            return "Same key as “Hold to interact with your Mac”, pick a different one"
        }
        return "Hold the key while the pointer is on"
    }

    @ObservedObject var model: SettingsModel
    private static let fadeChoices: [(String, Double)] = [
        ("After 3 seconds", 3),
        ("After 6 seconds", 6),
        ("After 10 seconds", 10),
        ("Keep until cleared", 0),
    ]

    private static var inkDetail: String {
        switch Preferences.inkChoice {
        case .rainbow: return "Rainbow colour"
        case .match: return "Matches each pointer"
        default: return "All pointers draw in \(Preferences.inkChoice.title.lowercased())"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            inkCard
            colorCard
            tapCard
        }
    }

    /// A slider that looks continuous (no tick marks) but snaps to whole steps,
    /// because the stored value is rounded and read back.
    private func snappingSlider<Low: View, High: View>(_ get: @escaping () -> Int, _ set: @escaping (Int) -> Void,
                                                       in range: ClosedRange<Int>, step: Int, low: Low, high: High) -> some View {
        IconSlider(value: model.binding({ Double(get()) }, { set(Int(($0 / Double(step)).rounded()) * step) }),
                   range: Double(range.lowerBound)...Double(range.upperBound), low: low, high: high)
    }

    private var inkCard: some View {
        Card(title: "Ink") {
            Row("Pointer size") {
                IconSlider(value: model.binding({ Double(Preferences.pointerSize) }, { v in
                    // Five stops from smallest to largest, the middle one in the centre.
                    let r = Preferences.pointerSizeRange
                    let k = ((CGFloat(v) - r.lowerBound) / (r.upperBound - r.lowerBound) * 4).rounded()
                    Preferences.pointerSize = r.lowerBound + k / 4 * (r.upperBound - r.lowerBound)
                }),
                           range: Double(Preferences.pointerSizeRange.lowerBound)...Double(Preferences.pointerSizeRange.upperBound),
                           low: Image(systemName: "hand.point.up.left.fill").font(.system(size: 10)),
                           high: Image(systemName: "hand.point.up.left.fill").font(.system(size: 16)))
            }
            Row("Stroke size", detail: "\(Preferences.strokeSize) pt") {
                snappingSlider({ Preferences.strokeSize }, { Preferences.strokeSize = $0 },
                               in: Preferences.strokeSizeRange, step: 1,
                               low: Image(systemName: "scribble").font(.system(size: 10, weight: .light)),
                               high: Image(systemName: "scribble").font(.system(size: 16, weight: .heavy)))
            }
            Row("Opacity", detail: "\(Preferences.inkOpacity)%") {
                snappingSlider({ Preferences.inkOpacity }, { Preferences.inkOpacity = $0 }, in: 10...100, step: 1,
                               low: Image(systemName: "circle.fill").font(.system(size: 12)).opacity(0.2),
                               high: Image(systemName: "circle.fill").font(.system(size: 12)))
            }
            Row("Smoothing", detail: "\(Preferences.strokeSmoothing.title), evens out shaky lines") {
                IconSlider(value: model.binding({ Double(Preferences.strokeSmoothing.rawValue) },
                                                { Preferences.strokeSmoothing = StrokeSmoothing(rawValue: Int($0.rounded())) ?? .off }),
                           range: 0...Double(StrokeSmoothing.allCases.count - 1),
                           low: Image(systemName: "scribble").font(.system(size: 14)),
                           high: Image(systemName: "line.diagonal").font(.system(size: 14)))
            }
            Row("Lines fade", detail: "Clear them any time with \(Preferences.clearShortcut.display)") {
                Picker("", selection: model.binding({ Preferences.fadeSeconds }, { Preferences.fadeSeconds = $0 })) {
                    ForEach(DrawingPage.fadeChoices, id: \.1) { choice in
                        Text(choice.0).tag(choice.1)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                    // White pop-up without the blue accent on its arrows (where macOS lets us).
                    .tint(Color(white: 0.55))
                .fixedSize()
                .focusable(false)
            }
        }
    }

    private var colorCard: some View {
        Card(title: "Color") {
            Row("Ink colour", detail: DrawingPage.inkDetail) {
                HStack(spacing: 8) {
                    ForEach(InkChoice.allCases, id: \.self) { choice in
                        InkSwatch(choice: choice, selected: Preferences.inkChoice == choice) {
                            Preferences.inkChoice = choice
                            model.refresh()
                        }
                    }
                }
            }
            if Preferences.inkChoice == .rainbow {
                Row("Rainbow speed", detail: "How quickly a line runs through the colours") {
                    snappingSlider({ Preferences.rainbowSpeed }, { Preferences.rainbowSpeed = $0 },
                                   in: Preferences.rainbowSpeedRange, step: 1,
                                   low: Image(systemName: "tortoise.fill").font(.system(size: 12)),
                                   high: Image(systemName: "hare.fill").font(.system(size: 12)))
                }
                Row("Rainbow shift per line", detail: "The rainbow spans 360°. Each new line starts this many degrees further along, until you clear") {
                    Picker("", selection: model.binding({ Preferences.rainbowStep }, { Preferences.rainbowStep = $0 })) {
                        ForEach(Preferences.rainbowStepChoices, id: \.self) { value in
                            Text("\(value)°").tag(value)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    // White pop-up without the blue accent on its arrows (where macOS lets us).
                    .tint(Color(white: 0.55))
                    .fixedSize()
                    .focusable(false)
                }
            }
        }
    }

    private var tapCard: some View {
        Card(title: "Tap") {
            Row("Show tap circle", detail: "A circle grows and fades out where you tap") {
                Toggle("", isOn: model.binding({ Preferences.tapRipples }, { Preferences.tapRipples = $0 }))
                    .toggleStyle(.switch).labelsHidden().focusable(false)
            }
        }
    }

}

/// A slider with an icon on each side. Icons sit in fixed-width slots and the track has a fixed
/// width, so sliders stacked in one card start and end at exactly the same place.
private struct IconSlider<Low: View, High: View>: View {
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let low: Low
    let high: High

    var body: some View {
        HStack(spacing: 10) {
            low.foregroundColor(.secondary).frame(width: 20, height: 20)
            Slider(value: value, in: range)
                .frame(width: 180)
                .focusable(false)
            high.foregroundColor(.secondary).frame(width: 20, height: 20)
        }
    }
}

private struct ToolbarPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Card(title: "Toolbar") {
                Row("Show toolbar", detail: "The bar at the bottom of the screen while Quite Handy is on") {
                    Toggle("", isOn: model.binding({ Preferences.showToolbar }, { Preferences.showToolbar = $0 }))
                        .toggleStyle(.switch).labelsHidden().focusable(false)
                }
                Row("Show colour palette") {
                    Toggle("", isOn: model.binding({ Preferences.showInkButton }, { Preferences.showInkButton = $0 }))
                        .toggleStyle(.switch).labelsHidden().focusable(false)
                        .disabled(!Preferences.showToolbar)
                }
                Row("Show opacity & size") {
                    Toggle("", isOn: model.binding({ Preferences.showKnobs }, { Preferences.showKnobs = $0 }))
                        .toggleStyle(.switch).labelsHidden().focusable(false)
                        .disabled(!Preferences.showToolbar)
                }
                Row("Position", detail: "Puts the toolbar back at the bottom middle of the screen") {
                    PillButton(title: "Reset Position") {
                        Preferences.toolbarPosition = nil
                        NotificationCenter.default.post(name: Preferences.toolbarPositionReset, object: nil)
                    }
                }
            }
            Card(title: "Whiteboard") {
                Row("Show whiteboard", detail: "The sheets of paper in the bottom right corner") {
                    Toggle("", isOn: model.binding({ Preferences.showWhiteboard }, { Preferences.showWhiteboard = $0 }))
                        .toggleStyle(.switch).labelsHidden().focusable(false)
                }
            }
        }
    }
}

private struct ZoomPage: View {
    @ObservedObject var model: SettingsModel

    static func factorText(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value))×" : String(format: "%.1f×", value)
    }

    static var sizeSwipe: String { Preferences.resizeVertically ? "vertically" : "horizontally" }
    static var zoomSwipe: String { Preferences.resizeVertically ? "horizontally" : "vertically" }

    static var directionDetail: String {
        let reverse = Preferences.reverseSwipe
        let size = Preferences.resizeVertically
            ? (reverse ? "Down makes it bigger" : "Up makes it bigger")
            : (reverse ? "Left makes it bigger" : "Right makes it bigger")
        guard Preferences.zoomOn else {
            return size
        }
        let zoom = Preferences.resizeVertically
            ? (reverse ? "left zooms in" : "right zooms in")
            : (reverse ? "down zooms in" : "up zooms in")
        return "\(size), \(zoom)"
    }

    /// Turns zoom on or off. Without Screen Recording, turning it on first explains that macOS
    /// asks for it in the next step, with the choice to keep the flashlight.
    static func setZoom(_ on: Bool) {
        guard on, !Permissions.screenRecording else {
            Preferences.zoomOn = on
            return
        }
        ZoomPermissionSheet.show { allowed in
            Preferences.zoomOn = allowed
            if allowed {
                Preferences.requestScreenRecordingIfNeeded()
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Card(title: "Flashlight") {
                Row("Hold to show", detail: DrawingPage.zoomKeyDetail, conflict: Conflicts.hold(Preferences.zoomKey.cgFlags)) {
                    Picker("", selection: model.binding({ Preferences.zoomKey }, { Preferences.zoomKey = $0 })) {
                        ForEach(HoldKey.allCases.filter { $0 != .off }, id: \.self) { key in
                            Text(key.title).tag(key)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    // White pop-up without the blue accent on its arrows (where macOS lets us).
                    .tint(Color(white: 0.55))
                    .fixedSize()
                    .focusable(false)
                }
                Row("Hold to change size and zoom factor", detail: "Hold the key while the flashlight is on and move the mouse (alternative to swiping on the trackpad)", conflict: Conflicts.hold(Preferences.loupeAdjustKey.cgFlags)) {
                    Picker("", selection: model.binding({ Preferences.loupeAdjustKey }, { Preferences.loupeAdjustKey = $0 })) {
                        ForEach(HoldKey.allCases, id: \.self) { key in
                            Text(key.title).tag(key)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    // White pop-up without the blue accent on its arrows (where macOS lets us).
                    .tint(Color(white: 0.55))
                    .fixedSize()
                    .focusable(false)
                }
                Row("Size", detail: "\(Preferences.loupeSize) pt, swipe \(ZoomPage.sizeSwipe) while you hold the key") {
                    IconSlider(value: model.binding({ Double(Preferences.loupeSize) },
                                                    { Preferences.loupeSize = Int(($0 / 20).rounded()) * 20 }),
                               range: Double(Preferences.loupeSizeRange.lowerBound)...Double(Preferences.loupeSizeRange.upperBound),
                               low: Image(systemName: "circle").font(.system(size: 10, weight: .bold)),
                               high: Image(systemName: "circle").font(.system(size: 16, weight: .bold)))
                }
                Row("Darkness", detail: "\(Int((Preferences.dimAlpha * 100).rounded()))% black around the circle") {
                    IconSlider(value: model.binding({ Preferences.dimAlpha }, { Preferences.dimAlpha = ($0 * 10).rounded() / 10 }),
                               range: Preferences.dimAlphaRange,
                               low: Image(systemName: "circle.fill").font(.system(size: 12)).opacity(0.2),
                               high: Image(systemName: "circle.fill").font(.system(size: 12)))
                }
                Row("Resize with", detail: Preferences.zoomOn ? "Zoom uses the other direction" : "Swipe direction for the size") {
                    Picker("", selection: model.binding({ Preferences.resizeVertically }, { Preferences.resizeVertically = $0 })) {
                        Text("Horizontal").tag(false)
                        Text("Vertical").tag(true)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .focusable(false)
                }
                Row("Reverse swipe direction", detail: ZoomPage.directionDetail) {
                    Toggle("", isOn: model.binding({ Preferences.reverseSwipe }, { Preferences.reverseSwipe = $0 }))
                        .toggleStyle(.switch).labelsHidden().focusable(false)
                }
                Row("Reverse mouse scroll", detail: "For a mouse wheel only, the trackpad follows the swipe direction above") {
                    Toggle("", isOn: model.binding({ Preferences.reverseMouseScroll }, { Preferences.reverseMouseScroll = $0 }))
                        .toggleStyle(.switch).labelsHidden().focusable(false)
                }
            }
            Card(title: "Zoom") {
                Row("Zoom", detail: "Magnifies the screen inside the circle (needs screen recording)") {
                    Toggle("", isOn: model.binding({ Preferences.zoomOn }, { ZoomPage.setZoom($0) }))
                        .toggleStyle(.switch).labelsHidden().focusable(false)
                }
                if Preferences.zoomOn {
                    if !Permissions.screenRecording {
                        Row("Screen Recording", detail: "Not allowed yet, you get the flashlight until it is") {
                            PillButton(title: "Open Settings") {
                                Preferences.requestScreenRecordingIfNeeded()
                            }
                        }
                    }
                    Row("Zoom factor", detail: "\(ZoomPage.factorText(Preferences.zoomFactor)), swipe \(ZoomPage.zoomSwipe) while you hold the key") {
                        IconSlider(value: model.binding({ Preferences.zoomFactor }, { Preferences.zoomFactor = ($0 * 2).rounded() / 2 }),
                                   range: Preferences.zoomFactorRange,
                                   low: Image(systemName: "magnifyingglass").font(.system(size: 10, weight: .bold)),
                                   high: Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .bold)))
                    }
                }
            }
        }
    }
}

private struct SoundPage: View {
    @ObservedObject var model: SettingsModel
    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 140), spacing: 8)]

    var body: some View {
        let on = Preferences.handSound
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Sound")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
                LazyVGrid(columns: columns, spacing: 8) {
                    SoundTile(title: "Off", symbol: "speaker.slash.fill", selected: !on) {
                        Preferences.handSound = false
                        model.refresh()
                    }
                    ForEach(TapSoundChoice.allCases, id: \.self) { choice in
                        SoundTile(title: choice.title, symbol: "waveform", selected: on && Preferences.tapSound == choice) {
                            Preferences.tapSound = choice
                            Preferences.handSound = true
                            model.preview(choice)
                            model.refresh()
                        }
                    }
                }
                Text("Click a sound to hear it. It plays each time the hand taps")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
            }
            Card(title: nil) {
                Row("Play sound", detail: "When you tap, or also when you start drawing") {
                    Picker("", selection: model.binding({ Preferences.soundOnDraw }, { Preferences.soundOnDraw = $0 })) {
                        Text("On tap").tag(false)
                        Text("On tap & draw").tag(true)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    // White pop-up without the blue accent on its arrows (where macOS lets us).
                    .tint(Color(white: 0.55))
                    .fixedSize()
                    .focusable(false)
                    .disabled(!on)
                }
                Row("Simple cursor taps too", detail: "Off by default, for quiet pointing") {
                    Toggle("", isOn: model.binding({ Preferences.colorPointerSound }, { Preferences.colorPointerSound = $0 }))
                        .toggleStyle(.switch).labelsHidden().focusable(false)
                        .disabled(!on)
                }
            }
            .opacity(on ? 1 : 0.5)
        }
        .onAppear { model.warmPreview() }
    }
}

private struct InkSwatch: View {
    let choice: InkChoice
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if choice == .rainbow {
                    Circle().fill(AngularGradient(colors: [.red, .yellow, .green, .blue, .purple, .red], center: .center))
                } else if let color = choice.color {
                    Circle().fill(Color(cgColor: color))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(choice == .black ? 0.35 : 0.15), lineWidth: 1))
                } else {
                    // Automatic colour: white with a black "A".
                    Circle().fill(Color.white)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                        .overlay(Text("A").font(.system(size: 11, weight: .bold)).foregroundColor(.black))
                }
            }
            .frame(width: 20, height: 20)
            .padding(3)
            .overlay(Circle().strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2))
            .scaleEffect(hovering && !selected ? 1.08 : 1)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(choice.title)
        .onHover { hovering = $0 }
    }
}

private struct SoundTile: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(selected ? .accentColor : .secondary)
                    .frame(height: 22)
                Text(title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundColor(selected ? .primary : .secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(hovering ? 0.07 : 0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.7) : Color.clear, lineWidth: 1.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
    }
}

private struct AboutPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 16) {
                if let icon = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage {
                    Image(nsImage: icon).resizable().frame(width: 72, height: 72)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Quite Handy").font(.system(size: 18, weight: .bold))
                    Text("Version \(version)").font(.system(size: 12)).foregroundColor(.secondary)
                    Text("For when you need a hand to talk about things on your screen").font(.system(size: 12)).foregroundColor(.secondary)
                }
                Spacer()
            }
            Card(title: nil) {
                LinkRow(title: "Made by", detail: "Eric Singhartinger", url: "https://github.com/esreverse")
                LinkRow(title: "Website", detail: "esreverse.com", url: "https://esreverse.com")
                LinkRow(title: "Source code", detail: "github.com/esreverse/quitehandy", url: "https://github.com/esreverse/quitehandy")
                LinkRow(title: "License", detail: "MIT, based on TinyHand by Kamran Ahmed", url: "https://github.com/esreverse/quitehandy/blob/main/LICENSE")
            }
            HStack {
                Spacer()
                TextButton(title: "Reset all settings") { model.resetAll() }
            }
        }
    }
}

private struct SidebarRow: View {
    let section: SettingsSection
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                IconTile(symbol: section.symbol, tint: section.tint)
                Text(section.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundColor(.primary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(selected ? 0.1 : hovering ? 0.05 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
    }
}

private struct IconTile: View {
    let symbol: String
    let tint: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(LinearGradient(colors: [tint.opacity(0.85), tint], startPoint: .top, endPoint: .bottom))
            .frame(width: 24, height: 24)
            .overlay(Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundColor(.white))
    }
}

private struct Card<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = title {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.leading, 4)
            }
            VStack(spacing: 0) {
                _VariadicView.Tree(Separated()) {
                    content
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
        }
    }
}

private struct Separated: _VariadicView_MultiViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        ForEach(children) { child in
            child
            if child.id != last {
                Rectangle()
                    .fill(Color.primary.opacity(0.07))
                    .frame(height: 1)
                    .padding(.leading, 14)
            }
        }
    }
}

/// The system green is hard to read on the light background, so light mode uses a deeper one.
private let allowedGreen = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? .systemGreen
        : NSColor(srgbRed: 0.10, green: 0.53, blue: 0.20, alpha: 1)
})

/// Keys that are used by more than one setting.
private enum Conflicts {
    private static var shortcuts: [Shortcut] {
        [Preferences.toggleShortcut, Preferences.clearShortcut, Preferences.toolbarShortcut,
         Preferences.nextPointerShortcut, Preferences.previousPointerShortcut, Preferences.rainbowInkShortcut,
         Preferences.matchInkShortcut, Preferences.nextInkShortcut, Preferences.previousInkShortcut, Preferences.soundShortcut, Preferences.undoShortcut, Preferences.redoShortcut,
         Preferences.copyScreenShortcut, Preferences.saveScreenShortcut]
    }

    private static var holdKeys: [CGEventFlags] {
        [Preferences.interactKey.cgFlags, Preferences.stampKey.cgFlags, Preferences.zoomKey.cgFlags,
         Preferences.loupeAdjustKey.cgFlags]
    }

    static func shortcut(_ s: Shortcut) -> Bool {
        !s.display.isEmpty && shortcuts.filter { $0.keyCode == s.keyCode && $0.modifiers == s.modifiers }.count > 1
    }

    static func hold(_ flags: CGEventFlags) -> Bool {
        !flags.isEmpty && holdKeys.filter { $0 == flags }.count > 1
    }
}

private struct Row<Trailing: View>: View {
    let title: String
    let detail: String?
    /// For permissions: shows a green "Allowed" or a red "Not yet allowed" after the detail.
    let allowed: Bool?
    /// Shows a red mark before the control: its key is also used by another setting.
    let conflict: Bool
    @ViewBuilder let trailing: Trailing

    init(_ title: String, detail: String? = nil, allowed: Bool? = nil, conflict: Bool = false, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.detail = detail
        self.allowed = allowed
        self.conflict = conflict
        self.trailing = trailing()
    }

    private func statusText(_ allowed: Bool) -> Text {
        let mark = Text(Image(systemName: allowed ? "checkmark" : "xmark")).font(.system(size: 8, weight: .heavy)).baselineOffset(1)
        return (mark + Text(allowed ? " Allowed" : " Not yet allowed"))
            .foregroundColor(allowed ? allowedGreen : .red)
    }


    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let detail = detail {
                    Text(detail).font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let allowed = allowed {
                    statusText(allowed).font(.system(size: 11))
                }
            }
            Spacer(minLength: 12)
            if conflict {
                Image(systemName: "exclamationmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .red)
                    .font(.system(size: 16))
                    .help("This key is also used by another setting")
            }
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minHeight: 48)
    }
}

private struct LinkRow: View {
    let title: String
    let detail: String
    let url: String
    @State private var hovering = false

    var body: some View {
        Button {
            if let u = URL(string: url) {
                NSWorkspace.shared.open(u)
            }
        } label: {
            HStack {
                Text(title).font(.system(size: 13)).foregroundColor(.primary)
                Spacer()
                Text(detail).font(.system(size: 12)).foregroundColor(.secondary)
                Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(Color.primary.opacity(hovering ? 0.04 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
    }
}

private struct TextButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(hovering ? .primary : .secondary)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
    }
}

private struct PillButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.primary.opacity(hovering ? 0.14 : 0.09)))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
    }
}

private struct MakeHandPage: View {
    @ObservedObject var model: SettingsModel
    @State private var dropping = false

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            Step(number: 1, title: "Describe it", detail: "What should your hand look like?") {
                PlainField(placeholder: "e.g. knitted wool in mustard yellow", text: $model.handIdea)
                    .frame(maxWidth: 420)
            }
            Step(number: 2, title: "Make the image", detail: "Open it in ChatGPT, or copy the prompt for another image tool. Download the result as a PNG with a transparent background") {
                HStack(spacing: 8) {
                    PrimaryButton(title: "Open in ChatGPT", symbol: "arrow.up.right") { model.openChatGPT() }
                    PrimaryButton(title: model.promptCopied ? "Copied" : "Copy prompt", symbol: model.promptCopied ? "checkmark" : "doc.on.doc", primary: false) {
                        model.copyPrompt()
                    }
                }
            }
            Step(number: 3, title: "Add it", detail: nil) {
                if let draft = model.draft {
                    preview(draft)
                } else {
                    dropZone
                }
            }
        }
    }

    private var dropZone: some View {
        Button {
            model.chooseHandFile()
        } label: {
            VStack(spacing: 8) {
                Image(systemName: model.draftError == nil ? "square.and.arrow.down" : "exclamationmark.triangle")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(model.draftError == nil ? .secondary : .orange)
                Text(model.draftError ?? "Drop the PNG here, or click to choose it")
                    .font(.system(size: 12))
                    .foregroundColor(model.draftError == nil ? .secondary : .primary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if model.draftError != nil {
                    Text("Try again with another image")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
            .frame(height: 130)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(dropping ? 0.07 : 0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(dropping ? Color.accentColor : Color.primary.opacity(0.14), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            guard let provider = providers.first else {
                return false
            }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url = url else {
                    return
                }
                DispatchQueue.main.async { model.loadDraft(url) }
            }
            return true
        }
    }

    private func preview(_ draft: SettingsModel.HandDraft) -> some View {
        HStack(alignment: .center, spacing: 22) {
            Image(nsImage: NSImage(cgImage: draft.image.cropping(to: CGRect(x: 112, y: 90, width: 800, height: 1000)) ?? draft.image, size: NSSize(width: 144, height: 180)))
                .resizable()
                .interpolation(.high)
                .frame(width: 144, height: 180)
                .padding(.vertical, 10)
                .frame(width: 170)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(red: 0.91, green: 0.81, blue: 0.71))
                )
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name").font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
                    PlainField(placeholder: "My hand", text: Binding(get: { model.handName }, set: { model.handName = String($0.prefix(16)) }))
                        .frame(width: 220)
                }
                Text("It should show the back of the hand, like the ones in Quite Handy. If you see the palm, try another image")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 300, alignment: .leading)
                HStack(spacing: 10) {
                    PrimaryButton(title: "Add hand", symbol: nil) { model.saveDraft() }
                    TextButton(title: "Use another image") { model.chooseHandFile() }
                }
            }
        }
    }
}

private struct Step<Content: View>: View {
    let number: Int
    let title: String
    let detail: String?
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.primary.opacity(0.75)))
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    if let detail = detail {
                        Text(detail).font(.system(size: 12)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                content
            }
        }
    }
}

private struct PlainField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
            )
            .modifier(NoFocusEffect())
    }
}

private struct NoFocusEffect: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.focusEffectDisabled()
        } else {
            content
        }
    }
}

private struct PrimaryButton: View {
    let title: String
    let symbol: String?
    var primary = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol = symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 14, height: 14)
                }
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(primary ? .white : .primary)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(Capsule().fill(primary
                ? Color.accentColor.opacity(hovering ? 0.88 : 1)
                : Color.primary.opacity(hovering ? 0.14 : 0.09)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
    }
}
private struct ShortcutField: NSViewRepresentable {
    let shortcut: Shortcut
    let model: SettingsModel
    var allowsBareKey = false
    let apply: (Shortcut) -> Bool

    func makeNSView(context: Context) -> ShortcutRecorder {
        let r = ShortcutRecorder(shortcut: shortcut)
        r.allowsBareKey = allowsBareKey
        r.onRecording = { model.onRecording?($0) }
        r.onChange = { s in
            let ok = apply(s)
            model.shortcutError = ok ? nil : "\(s.display) is already used by another app. Pick a different shortcut."
            return ok
        }
        return r
    }

    func updateNSView(_ nsView: ShortcutRecorder, context: Context) {
        nsView.show(shortcut)
    }
}

struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private let blankIcon = NSImage(size: NSSize(width: 64, height: 64))

private func pointerIcon(_ style: PointerStyle) -> NSImage? {
    guard let name = style.assetName else {
        return Toolbar.icon(for: style)
    }
    if let cached = HandAsset.cachedThumbnail(name) {
        return cached
    }
    // Screenshots render in one pass, so load the thumbnail right away there.
    return Permissions.screenshot ? HandAsset.thumbnail(name) ?? blankIcon : blankIcon
}


/// Asks before macOS's Screen Recording prompt, in larger type than a standard alert.
struct ZoomPermissionSheet: View {
    let onAnswer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let icon = NSImage(named: "settings_icon") ?? NSApp.applicationIconImage {
                Image(nsImage: icon).resizable().frame(width: 56, height: 56)
                    .padding(.bottom, 16)
            }
            Text("Zoom needs Screen Recording")
                .font(.system(size: 19, weight: .bold))
                .padding(.bottom, 12)
            Text("The loupe shows a magnified picture of your screen. macOS asks for the Screen Recording permission in the next step, turn on Quite Handy there.")
                .font(.system(size: 14))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 10)
            Text("The flashlight works without it.")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .padding(.bottom, 26)
            HStack(spacing: 10) {
                Spacer()
                SheetButton(title: "Keep the Flashlight", primary: false) { onAnswer(false) }
                    .keyboardShortcut(.cancelAction)
                SheetButton(title: "Continue", primary: true) { onAnswer(true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 440)
    }

    /// Shows the sheet on the key window (or as its own window) and reports the answer once.
    static func show(_ answer: @escaping (Bool) -> Void) {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let parent = NSApp.keyWindow
        let finish: (Bool) -> Void = { allowed in
            if let parent = parent {
                parent.endSheet(window)
            } else {
                window.close()
                NSApp.stopModal()
            }
            answer(allowed)
        }
        let host = NSHostingView(rootView: ZoomPermissionSheet(onAnswer: finish))
        window.contentView = host
        window.setContentSize(host.fittingSize)
        window.isReleasedWhenClosed = false
        if let parent = parent {
            parent.beginSheet(window)
        } else {
            window.center()
            NSApp.runModal(for: window)
        }
    }

    /// For --zoom-sheet-test.
    static func snapshot() -> NSBitmapImageRep? {
        let host = NSHostingView(rootView: ZoomPermissionSheet(onAnswer: { _ in })
            .background(Color(nsColor: .windowBackgroundColor)))
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            return nil
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }
}

private struct SheetButton: View {
    let title: String
    let primary: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(primary ? .white : .primary)
                .padding(.horizontal, 18)
                .frame(height: 34)
                .background(Capsule().fill(primary
                    ? Color.accentColor.opacity(hovering ? 0.88 : 1)
                    : Color.primary.opacity(hovering ? 0.14 : 0.09)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
