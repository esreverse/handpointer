import AppKit
import Carbon.HIToolbox

final class OverlayController {
    private final class OverlayWindow: NSWindow {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private let window: OverlayWindow
    /// The ink lives in its own window below the toolbar, so the toolbar stays on top of drawings
    /// while the hand (in `window`) stays on top of everything.
    private let inkWindow: OverlayWindow
    private let armView: ArmView
    private let inputTap = InputTap()
    private let tapSound = TapSound()
    private var interactHeld = false
    private var menuHover = false
    private var guardCursorUntil = Date.distantPast
    private var timer: Timer?
    private var currentFrame: CGRect?
    private var downPoint: CGPoint?
    private var buttonSeenDown = false
    private var dragEvents = 0

    private let toolbar = Toolbar()
    private let magnifier = Magnifier()
    private var draggingToolbar = false
    /// A press made while the zoom key is held: it does nothing at all, down, drag or up.
    private var ignoringPress = false
    private var revealUntil = Date.distantPast
    private var normalCursor = false
    private var ownMenuOpen = false
    private var menuRects: [CGRect] = []
    private var lastMenuScan = Date.distantPast
    private var menuOpeningUntil = Date.distantPast
    private var escHotKey: UInt32?
    private var lastPermissionCheck = Date.distantPast

    private static let busyInterval: TimeInterval = 1.0 / 120.0
    private static let idleInterval: TimeInterval = 1.0 / 20.0
    private static let idleAfter: TimeInterval = 0.5
    private static let menuScanFast: TimeInterval = 0.05
    private static let menuScanSlow: TimeInterval = 0.25
    private var timerInterval: TimeInterval = 0
    private var idleMonitors: [Any] = []
    private var lastMouse: CGPoint?
    private var stillSince = Date()
    private var lastButtonEvent = Date.distantPast

    private(set) var isActive = false
    private var activity: NSObjectProtocol?
    var onActiveChanged: (() -> Void)?
    var onNeedsPermission: (() -> Void)?

    init() {
        let frame = (NSScreen.main ?? NSScreen.screens.first).map { $0.frame }
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        window = OverlayWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        inkWindow = OverlayWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        inkWindow.isOpaque = false
        inkWindow.backgroundColor = .clear
        inkWindow.hasShadow = false
        inkWindow.ignoresMouseEvents = true
        inkWindow.isReleasedWhenClosed = false
        inkWindow.level = .screenSaver
        inkWindow.collectionBehavior = window.collectionBehavior

        armView = ArmView(frame: NSRect(origin: .zero, size: frame.size))
        let inkView = NSView(frame: NSRect(origin: .zero, size: frame.size))
        inkView.layer = CALayer()
        inkView.wantsLayer = true
        inkView.autoresizingMask = [.width, .height]
        inkView.layer?.addSublayer(armView.ink.layer)
        inkWindow.contentView = inkView
        window.contentView = armView

        inputTap.onMouseDown = { [weak self] in
            guard let self = self else {
                return
            }
            // The toolbar's drag handle: move the toolbar (right-click puts it back) instead of drawing.
            let mouse = NSEvent.mouseLocation
            // While zooming, clicks and drags never do anything.
            let zoomFlags = Preferences.zoomKey.cgFlags
            if !zoomFlags.isEmpty, CGEventSource.flagsState(.hidSystemState).contains(zoomFlags) {
                self.ignoringPress = true
                return
            }
            // Number stamp: place it where the button goes down; dragging moves it.
            let stampFlags = Preferences.stampKey.cgFlags
            if !stampFlags.isEmpty, CGEventSource.flagsState(.hidSystemState).contains(stampFlags),
               let p = self.localMouse() {
                // All nine numbers placed: a click with the stamp key does nothing.
                guard self.armView.ink.pressStamp(at: p) else {
                    self.ignoringPress = true
                    return
                }
                self.armView.press()
                self.armView.held = true
                self.tapSound.play()
                self.noteButtonEvent()
                return
            }
            if let handle = self.toolbar.handleFrame, handle.contains(mouse) {
                self.toolbar.startDrag(at: mouse)
                self.draggingToolbar = true
                self.noteButtonEvent()
                return
            }
            self.armView.press()
            self.armView.held = true
            if Preferences.soundOnDraw {
                self.tapSound.play()
            }
            self.toolbar.hideHint()
            self.downPoint = self.localMouse()
            self.dragEvents = 0
            Log.write("press at \(self.downPoint.map { "\(Int($0.x)),\(Int($0.y))" } ?? "?")")
            self.noteButtonEvent()
        }
        inputTap.onLeftDragged = { [weak self] in
            if self?.ignoringPress == true {
                return
            }
            if let self = self, self.armView.ink.isPlacingStamp {
                if let p = self.localMouse() {
                    self.armView.ink.moveStamp(to: p)
                }
                return
            }
            if let self = self, self.draggingToolbar {
                self.toolbar.continueDrag(to: NSEvent.mouseLocation)
                return
            }
            self?.dragEvents += 1
            self?.drag()
            self?.wake()
        }
        inputTap.onMouseUp = { [weak self] in
            if let self = self, self.ignoringPress {
                self.ignoringPress = false
                return
            }
            if let self = self, self.draggingToolbar {
                self.draggingToolbar = false
                self.toolbar.endDrag()
                return
            }
            if let self = self, self.armView.ink.isPlacingStamp {
                self.armView.held = false
                self.armView.ink.endStamp()
                self.noteButtonEvent()
                return
            }
            self?.release()
            self?.noteButtonEvent()
        }
        inputTap.onInteractDown = { [weak self] in
            self?.armView.press()
            self?.armView.held = true
            self?.noteButtonEvent()
        }
        inputTap.onInteractUp = { [weak self] in
            self?.armView.held = false
            self?.guardCursorUntil = Date().addingTimeInterval(2)
            CursorHider.reassert(urgent: true)
            self?.noteButtonEvent()
        }
        inputTap.onLoupeAdjust = { [weak self] dx, dy in
            // Mouse deltas grow downwards, like scroll deltas: up is negative in both.
            self?.scrollLoupe(dx: dx, dy: dy, phase: .changed, fromMouse: true)
        }
        inputTap.onStampDigit = { [weak self] digit in
            guard let self = self, let p = self.localMouse() else {
                return
            }
            self.armView.ink.renumberStamp(at: p, to: digit)
        }
        armView.ink.onStampPopped = { [weak self] in
            // Grown to full size and put down: the rest of this press does nothing.
            self?.armView.held = false
            self?.ignoringPress = true
        }
        inputTap.onLoupeScroll = { [weak self] dx, dy, phase in
            self?.scrollLoupe(dx: dx, dy: dy, phase: phase)
        }
        inputTap.onCaptureRightClick = { [weak self] in
            self?.toolbar.resetPosition()
            self?.noteButtonEvent()
        }
        inputTap.onRightClickExit = { [weak self] in
            self?.exit()
        }
        inputTap.rightClickExits = Preferences.rightClickExits
        inputTap.onPassThroughPress = { [weak self] location in
            guard let screen = self?.currentScreen() else {
                return
            }
            let bar = OverlayController.cgRect(OverlayController.menuBarRect(screen))
            if bar.contains(location) {
                self?.menuOpeningUntil = Date().addingTimeInterval(1)
            }
            self?.noteButtonEvent()
        }

        toolbar.currentInkColor = { [weak self] in
            guard let self = self else {
                return Ink.hex(0xFFFFFF)
            }
            return Preferences.inkChoice == .match ? Ink.hex(0xFFFFFF) : self.armView.ink.tapColor
        }
        toolbar.onPick = { [weak self] style in
            self?.pick(style)
        }
        toolbar.onToggleSound = { [weak self] in
            self?.soundOn.toggle()
        }
        toolbar.onExit = { [weak self] in
            self?.exit()
        }
        toolbar.onFixPermission = { [weak self] in
            self?.exit()
            self?.onNeedsPermission?()
        }
        toolbar.select(armView.style)
        tapSound.enabled = soundOn
        toolbar.setSoundOn(soundOn)
        NotificationCenter.default.addObserver(forName: Preferences.changed, object: nil, queue: .main) { [weak self] _ in
            self?.syncSound()
            self?.inputTap.interactKey = Preferences.interactKey.cgFlags
            self?.inputTap.rightClickExits = Preferences.rightClickExits
            self?.armView.updateInkColor()
            self?.tapSound.load(Preferences.tapSound)
            if let self = self, self.armView.style != PointerStyle.saved {
                self.pick(PointerStyle.saved)
            }
        }
    }

    /// The color pointer has its own "taps too" sound setting.
    private var usesDotSound: Bool { armView.style == .stroke }

    var soundOn: Bool {
        get { usesDotSound ? Preferences.colorPointerSound : Preferences.handSound }
        set {
            if usesDotSound {
                Preferences.colorPointerSound = newValue
            } else {
                Preferences.handSound = newValue
            }
        }
    }
    var onSoundChanged: (() -> Void)?

    func pick(_ style: PointerStyle) {
        armView.setStyle(style)
        PointerStyle.saved = armView.style
        toolbar.select(armView.style)
        syncSound()
    }

    /// Switches to the next (or previous) pointer in the toolbar, stopping at the first and last one.
    func cyclePointer(by step: Int) {
        let styles = PointerStyle.toolbarStyles
        guard !styles.isEmpty else {
            return
        }
        let index = styles.firstIndex(of: armView.style) ?? (step > 0 ? -1 : styles.count)
        let next = min(max(index + step, 0), styles.count - 1)
        guard styles[next] != armView.style else {
            return
        }
        pick(styles[next])
        wake()
    }

    private func syncSound() {
        tapSound.enabled = soundOn
        toolbar.setSoundOn(soundOn)
        onSoundChanged?()
    }

    var extraPassThrough: (() -> [CGRect])?

    func suspendInput(_ suspended: Bool) {
        guard isActive, inputTap.isInstalled else {
            return
        }
        ownMenuOpen = suspended
        inputTap.setActive(!suspended)
        if let screen = currentScreen() {
            updateZones(mouse: NSEvent.mouseLocation, screen: screen)
        }
    }

    func exit() {
        clearInk()
        deactivate()
    }

    private func release() {
        if let start = downPoint {
            let moved = localMouse().map { Int(hypot($0.x - start.x, $0.y - start.y)) } ?? -1
            Log.write("release, drag events=\(dragEvents) moved=\(moved)pt stroke drawn=\(armView.ink.isDrawing)")
            // A tap, not a drawing: released (almost) where it was pressed.
            let tapped = !armView.ink.isDrawing && moved >= 0 && moved <= 6
            if tapped && Preferences.tapRipples {
                armView.ripple(at: start)
            }
            if tapped && !Preferences.soundOnDraw {
                tapSound.play()
            }
        }
        buttonSeenDown = false
        armView.held = false
        downPoint = nil
        armView.ink.end()
        toolbar.refreshInk()
    }

    var style: PointerStyle { armView.style }

    var tapMaxWaitMs: Double { inputTap.maxWaitMs }

    func resetTapWait() {
        inputTap.resetWait()
    }

    func toolbarButtonCenter(_ style: PointerStyle) -> CGPoint? {
        toolbar.center(of: style)
    }

    var inkStrokes: Int { armView.ink.layer.sublayers?.count ?? 0 }

    var debugState: String {
        "held=\(armView.held) downPoint=\(downPoint != nil) drawing=\(armView.ink.isDrawing) strokes=\(inkStrokes)"
    }

    /// Shows or hides the toolbar from its shortcut; when shown, it pops up for a moment.
    func toggleToolbar() {
        Preferences.showToolbar.toggle()
        if Preferences.showToolbar {
            revealUntil = Date().addingTimeInterval(3)
        }
        wake()
    }

    /// Scroll distance not yet turned into a whole point of loupe size.
    private var loupeScrollRest: CGFloat = 0

    /// Swiping up and down drags the zoom factor freely; letting go snaps it to the nearest half step.
    private static let zoomStepDistance: CGFloat = 50
    private var zoomDrag: CGFloat?
    private var zoomDragBase: Double = 0
    private var zoomSnapTimer: Timer?

    /// Swipes on one axis resize the loupe (sideways by default), on the other they change the zoom
    /// factor – but only once zoom is turned on in Settings and Screen Recording is allowed.
    private var lastLoupeScroll = Date.distantPast

    /// Adjusting size and zoom by moving the mouse with the adjust key held (the loupe stays put).
    private var adjustingLoupe = false

    private func setAdjustingLoupe(_ on: Bool) {
        guard on != adjustingLoupe else {
            return
        }
        adjustingLoupe = on
        inputTap.loupeAdjusting = on
        // The loupe stays put while the mouse adjusts, then glides back to the pointer.
        magnifier.setAnchor(on ? NSEvent.mouseLocation : nil)
        scrollLoupe(dx: 0, dy: 0, phase: on ? .began : .ended, fromMouse: true)
    }

    private func scrollLoupe(dx: CGFloat, dy: CGFloat, phase: ScrollPhase, fromMouse: Bool = false) {
        let now = Date()
        if phase == .ended {
            finishZoomDrag()
            return
        }
        // A new trackpad swipe, or a pause without scroll events (mouse wheels), starts over.
        if phase == .began || now.timeIntervalSince(lastLoupeScroll) > 0.3 {
            finishZoomDrag()
            loupeScrollRest = 0
        }
        lastLoupeScroll = now
        // Both axes work at once: one resizes, the other zooms. A little zoom picked up while
        // resizing snaps back to its half step when the swipe ends.
        // Right and up count as positive; Settings can reverse that and swap which axis resizes.
        // Mouse moves follow the hand: right and up are always bigger and zoom in.
        let sign: CGFloat = Preferences.reverseSwipe && !fromMouse ? -1 : 1
        let horizontal = dx * sign
        let vertical = -dy * sign
        let sizeAmount = Preferences.resizeVertically ? vertical : horizontal
        let zoomAmount = Preferences.resizeVertically ? horizontal : vertical
        if sizeAmount != 0 {
            resizeLoupe(by: sizeAmount)
        }
        // Zoom only once it is turned on and allowed.
        guard zoomAmount != 0, Preferences.zoomOn, CGPreflightScreenCaptureAccess() else {
            return
        }
        if zoomDrag == nil {
            zoomDrag = 0
            zoomDragBase = Preferences.zoomFactor
        }
        zoomDrag! += zoomAmount
        magnifier.previewFactor = CGFloat(liveZoom())
        if phase == .wheel {
            // A mouse wheel never says when it's done: snap once it has been still for a moment.
            zoomSnapTimer?.invalidate()
            zoomSnapTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
                self?.finishZoomDrag()
            }
        }
    }

    private func liveZoom() -> Double {
        let raw = zoomDragBase + Double((zoomDrag ?? 0) / OverlayController.zoomStepDistance) * 0.5
        return min(Preferences.zoomFactorRange.upperBound, max(Preferences.zoomFactorRange.lowerBound, raw))
    }

    /// Ends a zoom swipe: the factor snaps (animated) to the nearest half step.
    private func finishZoomDrag() {
        zoomSnapTimer?.invalidate()
        zoomSnapTimer = nil
        guard zoomDrag != nil else {
            return
        }
        let snapped = (liveZoom() * 2).rounded() / 2
        zoomDrag = nil
        magnifier.previewFactor = nil
        Preferences.zoomFactor = snapped
    }

    private func resizeLoupe(by delta: CGFloat) {
        loupeScrollRest += delta * 2
        let step = loupeScrollRest.rounded(.towardZero)
        guard step != 0 else {
            return
        }
        loupeScrollRest -= step
        Preferences.loupeSize += Int(step)
    }

    func clearInk() {
        armView.ink.clear()
    }

    func undoInk() {
        armView.ink.undo()
    }

    func redoInk() {
        armView.ink.redo()
    }

    private func drag() {
        guard let start = downPoint, let p = localMouse() else {
            return
        }
        let ink = armView.ink
        if !ink.isDrawing {
            if hypot(p.x - start.x, p.y - start.y) < 4 {
                return
            }
            ink.begin(at: start, width: armView.inkWidth)
        }
        ink.extend(to: p)
    }

    private func localMouse() -> CGPoint? {
        guard let frame = currentFrame else {
            return nil
        }
        let mouse = NSEvent.mouseLocation
        return CGPoint(x: mouse.x - frame.origin.x, y: mouse.y - frame.origin.y)
    }

    func toggle() {
        if isActive {
            deactivate()
            return
        }
        activate()
    }

    static let hintShownKey = "firstRunHintShown"

    @discardableResult
    func activate() -> Bool {
        guard !isActive else {
            return inputTap.isInstalled
        }
        guard AXIsProcessTrusted() else {
            Log.write("activate skipped: not trusted")
            onNeedsPermission?()
            return false
        }
        isActive = true
        currentFrame = nil
        tapSound.warm()

        CursorHider.hide()
        tick()
        inkWindow.orderFrontRegardless()
        window.orderFrontRegardless()

        stillSince = Date()
        runTimer(every: OverlayController.busyInterval)

        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical], reason: "HandPointer pointer is on")
        let installed = inputTap.install()
        inputTap.interactKey = Preferences.interactKey.cgFlags
        inputTap.setActive(installed)
        Log.write("activate trusted=\(AXIsProcessTrusted()) tapInstalled=\(installed)")

        if let screen = currentScreen() {
            toolbar.place(on: screen)
        }
        toolbar.setNeedsPermission(!installed)
        toolbar.show()
        revealUntil = Date().addingTimeInterval(3)
        if installed && Preferences.showToolbar && !UserDefaults.standard.bool(forKey: OverlayController.hintShownKey) {
            UserDefaults.standard.set(true, forKey: OverlayController.hintShownKey)
            var parts: [(key: String, text: String)] = [("Click", "to tap"), ("Drag", "to draw")]
            if Preferences.interactKey != .off {
                parts.append(("Hold \(Preferences.interactKey.symbol)", "to click for real"))
            }
            parts.append(("Esc", "to exit"))
            toolbar.showHint(parts)
            revealUntil = Date().addingTimeInterval(10)
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                self?.toolbar.hideHint()
            }
        }
        setEscEnabled(true)
        onActiveChanged?()
        return installed
    }

    func deactivate() {
        guard isActive else {
            return
        }
        isActive = false
        setAdjustingLoupe(false)

        timer?.invalidate()
        timer = nil
        timerInterval = 0
        removeIdleMonitors()
        inputTap.setActive(false)
        if let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
        armView.held = false
        downPoint = nil
        armView.ink.clear()
        magnifier.reset()
        armView.hiddenForZoom = false
        window.ignoresMouseEvents = true
        window.orderOut(nil)
        inkWindow.orderOut(nil)
        toolbar.hide()
        normalCursor = false
        armView.pointerHidden = false
        inputTap.passThroughRects = []
        setEscEnabled(false)
        ownMenuOpen = false
        CursorHider.show()
        onActiveChanged?()
    }

    private func updateZones(mouse: CGPoint, screen: NSScreen) {
        let f = toolbar.frame
        let near = f.insetBy(dx: -80, dy: 0).union(f.offsetBy(dx: 0, dy: 90)).insetBy(dx: 0, dy: -10).contains(mouse)
        let needsPermission = !inputTap.isInstalled
        let drawing = armView.ink.isDrawing
        let key = Preferences.interactKey.cgFlags
        let interacting = (!key.isEmpty && CGEventSource.flagsState(.hidSystemState).contains(key)) || inputTap.interactPressing
        let wantToolbar = Preferences.showToolbar || needsPermission
        // While the interact key is held the toolbar gets out of the way at once, without fading.
        toolbar.setRevealed(wantToolbar && !drawing && !interacting && (near || Date() < revealUntil || needsPermission),
                            animated: !interacting)

        let menuLikely = !menuRects.isEmpty || ownMenuOpen || Date() < menuOpeningUntil
            || Date().timeIntervalSince(lastButtonEvent) < 2
            || OverlayController.menuBarRect(screen).insetBy(dx: 0, dy: -40).contains(mouse)
        let scanEvery = menuLikely ? OverlayController.menuScanFast : OverlayController.menuScanSlow
        if Date().timeIntervalSince(lastMenuScan) > scanEvery {
            lastMenuScan = Date()
            menuRects = OverlayController.openMenus()
        }
        let menuBar = OverlayController.menuBarRect(screen)
        let cgMouse = OverlayController.cgPoint(mouse)
        let overMenu = menuBar.contains(mouse) || menuRects.contains { $0.contains(cgMouse) }
            || Date() < menuOpeningUntil
        interactHeld = interacting
        menuHover = overMenu
        let normal = !drawing && !Preferences.interactKeepsHand && (interacting || overMenu || ownMenuOpen)
        setEscEnabled(menuRects.isEmpty && !ownMenuOpen)

        if normal != normalCursor {
            let at = "at \(Int(mouse.x)),\(Int(mouse.y))"
            let why = interacting ? "interact key" : menuBar.contains(mouse) ? "menu bar" : "menu"
            Log.write(normal ? "real cursor (\(why)) \(at)" : "pointer back \(at)")
            normalCursor = normal
            armView.pointerHidden = normal
            if normal {
                CursorHider.show()
            } else {
                CursorHider.hide()
            }
        }

        var rects = (extraPassThrough?() ?? []).map(OverlayController.cgRect)
        rects.append(OverlayController.cgRect(menuBar))
        rects.append(contentsOf: menuRects)
        if toolbar.revealed {
            rects.append(OverlayController.cgRect(f))
        }
        inputTap.passThroughRects = rects
        toolbar.updateHover(mouse: mouse)
        inputTap.captureRects = toolbar.handleFrame.map { [OverlayController.cgRect($0)] } ?? []
        inputTap.rightExitRects = toolbar.revealed ? [OverlayController.cgRect(f)] : []
    }

    private func setEscEnabled(_ enabled: Bool) {
        if enabled && isActive && escHotKey == nil {
            escHotKey = HotKeyCenter.shared.register(keyCode: UInt32(kVK_Escape), modifiers: 0) { [weak self] in
                self?.exit()
            }
        }
        if !enabled, let id = escHotKey {
            HotKeyCenter.shared.unregister(id)
            escHotKey = nil
        }
    }

    private static func menuBarRect(_ screen: NSScreen) -> CGRect {
        let height = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
        return CGRect(x: screen.frame.minX, y: screen.frame.maxY - height, width: screen.frame.width, height: height)
    }

    private static func openMenus() -> [CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else {
            return []
        }
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == menuLevel,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else {
                return nil
            }
            return rect
        }
    }

    private static func cgPoint(_ p: CGPoint) -> CGPoint {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: p.x, y: primaryH - p.y)
    }

    private func checkPermission() {
        guard !inputTap.isInstalled, Date().timeIntervalSince(lastPermissionCheck) > 1 else {
            return
        }
        lastPermissionCheck = Date()
        guard AXIsProcessTrusted(), inputTap.install() else {
            return
        }
        Log.write("permission granted while running; tap installed")
        inputTap.setActive(true)
        toolbar.setNeedsPermission(false)
    }

    private static func cgRect(_ r: CGRect) -> CGRect {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: r.minX, y: primaryH - r.maxY, width: r.width, height: r.height)
    }

    func runClickTest() {
        func time(_ label: String, _ body: () -> Void) {
            let t = CFAbsoluteTimeGetCurrent()
            body()
            print(String(format: "%@: %.1f ms", label, (CFAbsoluteTimeGetCurrent() - t) * 1000))
        }
        func spin(_ seconds: Double) {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        }
        tick()
        time("tick") { tick() }
        time("mouseDown (tap callback)") { inputTap.simulate(.leftMouseDown) }
        time("mouseDown (deferred work)") { spin(0.01) }
        time("10 ticks while held") { for _ in 0..<10 { tick() } }
        time("mouseUp (tap callback)") { inputTap.simulate(.leftMouseUp) }
        spin(0.01)
        spin(0.3)
        time("second click (tap callbacks)") {
            inputTap.simulate(.leftMouseDown)
            inputTap.simulate(.leftMouseUp)
        }
        spin(0.05)
        time("drag x50 (tap callbacks)") {
            inputTap.simulate(.leftMouseDown)
            for _ in 0..<50 { inputTap.simulate(.leftMouseDragged) }
            inputTap.simulate(.leftMouseUp)
        }
        spin(0.05)
        time("ticks after up") { for _ in 0..<20 { tick() } }
        print("held after up:", armView.held, "drawing:", armView.ink.isDrawing)
    }

    private func currentScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func runTimer(every interval: TimeInterval) {
        if timer != nil && interval == timerInterval {
            return
        }
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        timerInterval = interval
    }

    private func noteButtonEvent() {
        lastButtonEvent = Date()
        wake()
    }

    private func wake() {
        stillSince = Date()
        guard isActive, timerInterval != OverlayController.busyInterval else {
            return
        }
        removeIdleMonitors()
        runTimer(every: OverlayController.busyInterval)
        tick()
    }

    private func updatePace(busy: Bool) {
        if timerInterval == OverlayController.idleInterval {
            if busy {
                wake()
            }
            return
        }
        let still = Date().timeIntervalSince(stillSince) > OverlayController.idleAfter
        guard still, !busy, !armView.held, !armView.isSettling, !armView.ink.isDrawing else {
            return
        }
        installIdleMonitors()
        runTimer(every: OverlayController.idleInterval)
    }

    private func installIdleMonitors() {
        guard idleMonitors.isEmpty else {
            return
        }
        let events: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .rightMouseDown, .otherMouseDown, .flagsChanged,
        ]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
            self?.wake()
        }) {
            idleMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            self?.wake()
            return event
        }) {
            idleMonitors.append(local)
        }
    }

    private func removeIdleMonitors() {
        idleMonitors.forEach(NSEvent.removeMonitor)
        idleMonitors = []
    }

    private func tick() {
        let mouse = NSEvent.mouseLocation
        guard let screen = currentScreen() else {
            return
        }

        if currentFrame != screen.frame {
            let moving = currentFrame != nil
            currentFrame = screen.frame
            if moving {
                release()
                revealUntil = Date().addingTimeInterval(1.5)
            }
            armView.ink.clear()
            window.setFrame(screen.frame, display: false)
            inkWindow.setFrame(screen.frame, display: false)
            armView.frame = NSRect(origin: .zero, size: screen.frame.size)
            toolbar.place(on: screen)
        }

        if mouse != lastMouse {
            lastMouse = mouse
            stillSince = Date()
        }

        updateZones(mouse: mouse, screen: screen)
        let zoomFlags = Preferences.zoomKey.cgFlags
        let zoomHeld = !zoomFlags.isEmpty && !interactHeld
            && CGEventSource.flagsState(.hidSystemState).contains(zoomFlags)
        let adjustFlags = Preferences.loupeAdjustKey.cgFlags
        setAdjustingLoupe(zoomHeld && magnifier.isShowing && !adjustFlags.isEmpty
            && CGEventSource.flagsState(.hidSystemState).contains(adjustFlags))
        if !zoomHeld {
            finishZoomDrag()
        }
        magnifier.update(held: zoomHeld, mouse: mouse, screen: screen)
        armView.hiddenForZoom = magnifier.isShowing
        inputTap.loupeShowing = magnifier.isShowing
        inputTap.hoveringStamp = localMouse().map { armView.ink.stamp(at: $0) != nil } ?? false
        let overDock = DockArea.contains(OverlayController.cgPoint(mouse))
        let overToolbar = toolbar.revealed && toolbar.frame.contains(mouse)
        let catchMouse = overDock && !overToolbar && inputTap.isInstalled && !normalCursor && !interactHeld
        if window.ignoresMouseEvents == catchMouse {
            window.ignoresMouseEvents = !catchMouse
        }
        let urgent = interactHeld || menuHover || Date() < guardCursorUntil
        if !normalCursor {
            CursorHider.reassert(fighting: overDock, urgent: urgent)
        }
        checkPermission()

        let local = CGPoint(x: mouse.x - screen.frame.origin.x, y: mouse.y - screen.frame.origin.y)
        armView.aim(cursor: local)
        guard downPoint != nil else {
            let busy = overDock || (!normalCursor && urgent) || CursorHider.isSettling || magnifier.isBusy
            updatePace(busy: busy)
            return
        }
        let down = CGEventSource.buttonState(.hidSystemState, button: .left)
        if down {
            buttonSeenDown = true
        }
        if buttonSeenDown && !down {
            release()
            return
        }
        drag()
    }
}
