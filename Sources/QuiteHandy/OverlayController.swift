import AppKit
import ScreenCaptureKit
import Carbon.HIToolbox

final class OverlayController {
    /// The click sound that is loaded, so a settings change only reloads it when it changed.
    private var loadedTapSound: TapSoundChoice?
    private final class OverlayWindow: NSWindow {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private let window: OverlayWindow
    /// The ink lives in its own window below the toolbar, so the toolbar stays on top of drawings
    /// while the hand (in `window`) stays on top of everything.
    private let inkWindow: OverlayWindow
    private let armView: ArmView
    private let whiteboard: Whiteboard
    /// One undo/redo history for screen ink, whiteboard ink and the whiteboard itself.
    private let history = History()
    /// A press on the whiteboard's sheet, handles or floating board, followed until mouse up.
    private var boardGesture: (hit: Whiteboard.Hit, board: Whiteboard.Board?)?
    /// The whiteboard the current press draws on (nil: the screen).
    private var targetBoard: Whiteboard.Board?
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
    /// The cog above the sheet in the corner.
    var onOpenSettings: (() -> Void)?

    init() {
        let frame = (NSScreen.main ?? NSScreen.screens.first).map { $0.frame }
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        window = OverlayWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        // No zoom-in when shown: macOS would grow it from smaller, cutting off its edges.
        window.animationBehavior = .none
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        inkWindow = OverlayWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        inkWindow.isOpaque = false
        inkWindow.backgroundColor = .clear
        inkWindow.hasShadow = false
        inkWindow.ignoresMouseEvents = true
        inkWindow.isReleasedWhenClosed = false
        // No zoom-in when shown: macOS would grow it from smaller, cutting off its edges.
        inkWindow.animationBehavior = .none
        inkWindow.level = .screenSaver
        inkWindow.collectionBehavior = window.collectionBehavior

        let arm = ArmView(frame: NSRect(origin: .zero, size: frame.size))
        armView = arm
        whiteboard = Whiteboard()
        let inkView = NSView(frame: NSRect(origin: .zero, size: frame.size))
        inkView.layer = CALayer()
        inkView.wantsLayer = true
        inkView.autoresizingMask = [.width, .height]
        inkView.layer?.addSublayer(armView.screenInk.layer)
        inkWindow.contentView = inkView
        window.contentView = armView

        history.board = whiteboard
        armView.screenInk.onRecord = { [weak self] ink in self?.history.add(.ink(ink)) }
        whiteboard.onInkRecord = { [weak self] ink in self?.history.add(.ink(ink)) }
        whiteboard.onChange = { [weak self] b, from, to in self?.history.add(.board(b, from, to)) }

        inputTap.onMouseDown = { [weak self] in
            guard let self = self else {
                return
            }
            // The toolbar's drag handle: move the toolbar instead of drawing.
            let mouse = NSEvent.mouseLocation
            // While zooming, clicks and drags never do anything.
            let zoomFlags = Preferences.zoomKey.cgFlags
            if !zoomFlags.isEmpty, HeldKeys.current.contains(zoomFlags) {
                self.ignoringPress = true
                return
            }
            // The whiteboards: the sheets in the corner, and each board's buttons, handles and grip.
            // A press on a board brings it to the front and draws on it; elsewhere on the screen.
            if let p = self.localMouse() {
                let (hit, board) = self.whiteboard.hit(p)
                if let board = board {
                    self.whiteboard.bringToFront(board)
                }
                self.targetBoard = board
                self.armView.targetInk = board?.ink
                switch hit {
                case .peek:
                    self.history.beginGroup()
                    self.whiteboard.beginPull(at: p)
                    self.boardGesture = (.peek, nil)
                    self.noteButtonEvent()
                    return
                case .settings:
                    self.ignoringPress = true
                    self.noteButtonEvent()
                    DispatchQueue.main.async { self.onOpenSettings?() }
                    return
                case .close, .save, .copy, .theme:
                    if let board = board {
                        self.whiteboard.press(board, hit)
                    }
                    self.ignoringPress = true
                    self.noteButtonEvent()
                    return
                case .topLeft, .bottomRight:
                    if let board = board {
                        self.whiteboard.beginResize(board, hit, at: p)
                    }
                    self.boardGesture = (hit, board)
                    self.noteButtonEvent()
                    return
                case .floating, .grip:
                    if let board = board {
                        self.whiteboard.grab(board, at: p)
                    }
                    self.boardGesture = (.floating, board)
                    self.noteButtonEvent()
                    return
                case .board, .none:
                    break
                }
            }
            // Number stamp: place it where the button goes down; dragging moves it.
            let stampFlags = Preferences.stampKey.cgFlags
            if !stampFlags.isEmpty, HeldKeys.current.contains(stampFlags),
               let p = self.inkMouse() {
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
            if let self = self, let gesture = self.boardGesture, let p = self.localMouse() {
                switch gesture.hit {
                case .peek: self.whiteboard.pull(to: p)
                case .floating: self.whiteboard.carry(to: p)
                default:
                    if let board = gesture.board {
                        self.whiteboard.drag(board, gesture.hit, to: p)
                    }
                }
                self.wake()
                return
            }
            if let self = self, self.armView.ink.isPlacingStamp {
                if let p = self.inkMouse() {
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
            if let self = self, let gesture = self.boardGesture {
                self.boardGesture = nil
                switch gesture.hit {
                case .peek:
                    self.whiteboard.endPull()
                    self.history.endGroup()
                case .floating:
                    self.whiteboard.drop()
                default:
                    if let board = gesture.board {
                        self.whiteboard.endResize(board)
                    }
                }
                self.noteButtonEvent()
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
        inputTap.onEsc = { [weak self] in self?.exit() }
        inputTap.onKeyWhileLoupe = { [weak self] in
            guard let self = self, self.magnifier.isShowing else {
                return
            }
            self.cancelZoom()
        }
        inputTap.onStampDigit = { [weak self] digit in
            guard let self = self, let p = self.localMouse() else {
                return
            }
            let (ink, q) = self.inkAndPoint(at: p)
            ink.renumberStamp(at: q, to: digit)
        }
        let popped: () -> Void = { [weak self] in
            // Grown to full size and put down: the rest of this press does nothing.
            self?.armView.held = false
            self?.ignoringPress = true
        }
        armView.screenInk.onStampPopped = popped
        whiteboard.onStampPopped = popped
        inputTap.onLoupeScroll = { [weak self] dx, dy, phase in
            self?.scrollLoupe(dx: dx, dy: dy, phase: phase)
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
        NotificationCenter.default.addObserver(forName: Preferences.toolbarPositionReset, object: nil, queue: .main) { [weak self] _ in
            self?.toolbar.resetPosition()
        }
        NotificationCenter.default.addObserver(forName: Preferences.changed, object: nil, queue: .main) { [weak self] _ in
            self?.syncSound()
            self?.inputTap.interactKey = Preferences.interactKey.cgFlags
            self?.inputTap.rightClickExits = Preferences.rightClickExits
            self?.armView.updateInkColor()
            self?.whiteboard.setSheetsShown(Preferences.showWhiteboard)
            if let self = self, self.loadedTapSound != Preferences.tapSound {
                self.loadedTapSound = Preferences.tapSound
                self.tapSound.load(Preferences.tapSound)
            }
            if let self = self, self.armView.style != PointerStyle.saved {
                self.pick(PointerStyle.saved)
            }
        }
    }

    /// The simple cursor has its own "taps too" sound setting.
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

    /// Right click or Esc: everything goes, screen and whiteboard.
    func exit() {
        armView.screenInk.clear()
        whiteboard.reset()
        history.clear()
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
        // A mouse wheel (no swipe phases) has its own reverse setting; the trackpad uses the
        // swipe one.
        let reverse = phase == .wheel ? Preferences.reverseMouseScroll : Preferences.reverseSwipe
        let sign: CGFloat = reverse && !fromMouse ? -1 : 1
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

    /// Clears the board under the pointer, or the screen when there is none.
    /// ⌘C / ⌘S: over a whiteboard, that board; elsewhere a picture of the whole screen under the
    /// pointer, with drawings and whiteboards but without the hand, the toolbar and the sheets in
    /// the corner. Copied, or saved on the desktop.
    func captureScreen(save: Bool) {
        // Over a whiteboard: just that board (the topmost one under the pointer), like its own
        // copy and save buttons.
        if let p = localMouse(), let board = whiteboard.board(at: p) {
            whiteboard.press(board, save ? .save : .copy)
            return
        }
        guard #available(macOS 14.0, *) else {
            whiteboard.showScreenToast("Needs macOS 14 or later", success: false)
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            whiteboard.showScreenToast("Allow screen recording in Settings first", success: false)
            return
        }
        guard let screen = currentScreen(), let id = screen.displayID else {
            return
        }
        let skip = Set([window.windowNumber, toolbar.windowNumber])
        let scale = screen.backingScaleFactor
        whiteboard.setCornerHidden(true)
        // Give the corner a frame to disappear before the picture is taken.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, _ in
                guard let content = content, let display = content.displays.first(where: { $0.displayID == id }) else {
                    DispatchQueue.main.async { self?.whiteboard.setCornerHidden(false) }
                    return
                }
                let excluded = content.windows.filter { skip.contains(Int($0.windowID)) }
                let filter = SCContentFilter(display: display, excludingWindows: excluded)
                let config = SCStreamConfiguration()
                config.width = Int(CGFloat(display.width) * scale)
                config.height = Int(CGFloat(display.height) * scale)
                config.showsCursor = false
                SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, _ in
                    let png = image.flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
                    DispatchQueue.main.async {
                        guard let self = self else {
                            return
                        }
                        self.whiteboard.setCornerHidden(false)
                        guard let png = png else {
                            self.whiteboard.showScreenToast("Could not take the screenshot", success: false)
                            return
                        }
                        if save {
                            let f = DateFormatter()
                            f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
                            let url = FileManager.default.homeDirectoryForCurrentUser
                                .appendingPathComponent("Desktop/Quite Handy \(f.string(from: Date())).png")
                            if (try? png.write(to: url)) != nil {
                                self.whiteboard.showScreenToast("Screenshot saved to desktop", success: true)
                            } else {
                                self.whiteboard.showScreenToast("Could not save the screenshot", success: false)
                            }
                        } else {
                            let pb = NSPasteboard.general
                            pb.clearContents()
                            pb.setData(png, forType: .png)
                            self.whiteboard.showScreenToast("Screenshot copied to clipboard", success: true)
                        }
                    }
                }
            }
        }
    }

    /// Set when the flashlight/loupe was cut off by another key; cleared when the zoom key goes up.
    private var zoomCancelled = false

    private func cancelZoom() {
        guard !zoomCancelled else {
            return
        }
        zoomCancelled = true
        finishZoomDrag()
        magnifier.reset()
        armView.hiddenForZoom = false
    }

    /// After a colour shortcut: the new colour shows for a moment next to the fingertip.
    func flashInkColor() {
        armView.flashInk()
        wake()
    }

    func clearInk() {
        let p = localMouse() ?? .zero
        inkAndPoint(at: p).ink.clear()
    }

    /// The ink under `p` (the topmost board's, or the screen's) and `p` in its coordinates.
    private func inkAndPoint(at p: CGPoint) -> (ink: Ink, point: CGPoint) {
        if let b = whiteboard.board(at: p) {
            return (b.ink, CGPoint(x: p.x - b.offset.x, y: p.y - b.offset.y))
        }
        return (armView.screenInk, p)
    }

    /// `p` in the coordinates of the ink being drawn on now.
    private func inkPoint(_ p: CGPoint) -> CGPoint {
        guard let b = targetBoard else {
            return p
        }
        return CGPoint(x: p.x - b.offset.x, y: p.y - b.offset.y)
    }

    private func inkMouse() -> CGPoint? {
        localMouse().map(inkPoint)
    }

    func undoInk() {
        history.undo()
    }

    func redoInk() {
        history.redo()
    }

    private func drag() {
        guard let start = downPoint.map(inkPoint), let p = inkMouse() else {
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
        // A flashlight key still held from the shortcut that turned us on (⌃ of ⌃⇥) doesn't
        // count: the flashlight only comes with the next press.
        let zoomFlags = Preferences.zoomKey.cgFlags
        zoomCancelled = !zoomFlags.isEmpty && HeldKeys.current.contains(zoomFlags)
        tapSound.warm()

        CursorHider.hide()
        tick()
        // Our own entrance (macOS's window animation would cut off the edges): the hand grows
        // in, the sheets slide in from the bottom right.
        armView.animateIn()
        whiteboard.animateIn()
        inkWindow.orderFrontRegardless()
        window.orderFrontRegardless()

        stillSince = Date()
        runTimer(every: OverlayController.busyInterval)

        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical], reason: "QuiteHandy pointer is on")
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
        armView.targetInk = nil
        targetBoard = nil
        armView.screenInk.clear()
        magnifier.reset()
        armView.hiddenForZoom = false
        window.ignoresMouseEvents = true
        window.orderOut(nil)
        inkWindow.orderOut(nil)
        whiteboard.hide()
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
        let interacting = (!key.isEmpty && HeldKeys.current.contains(key)) || inputTap.interactPressing
        let wantToolbar = Preferences.showToolbar || needsPermission
        // While the interact key is held the toolbar gets out of the way at once, without fading.
        toolbar.setRevealed(wantToolbar && !drawing && !interacting
                            && (near || toolbar.isAdjusting || Date() < revealUntil || needsPermission),
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

    /// Esc ends the session, except while a menu (or another app's window above ours) is open:
    /// then Esc is for that.
    private func setEscEnabled(_ enabled: Bool) {
        inputTap.escExits = enabled && isActive
    }

    private static func menuBarRect(_ screen: NSScreen) -> CGRect {
        let height = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
        return CGRect(x: screen.frame.minX, y: screen.frame.maxY - height, width: screen.frame.width, height: height)
    }

    /// Open menus, and other apps' windows that lie above ours: clicks there go to them.
    private static func openMenus() -> [CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else {
            return []
        }
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        // Windows of other apps above our own (screensaver level and up): a screenshot tool's
        // layer for picking an area (⇧⌘4, ⇧⌘5 or any other tool) lies over the hand and the
        // drawing, so clicks there are meant for it, like clicks in a menu.
        // Only windows that cover most of a screen count: small ones up there (the screen
        // recording indicator, for one) must not take clicks or Esc away.
        let ourTop = Int(CGWindowLevelForKey(.screenSaverWindow)) + 4
        let me = getpid()
        let screens = NSScreen.screens.map { $0.frame.size }
        return list.compactMap { info in
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            let pid = info[kCGWindowOwnerPID as String] as? pid_t ?? 0
            guard layer == menuLevel || (layer > ourTop && pid != me),
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else {
                return nil
            }
            if layer != menuLevel {
                let covers = screens.contains { rect.width * rect.height >= 0.5 * $0.width * $0.height }
                guard covers else {
                    return nil
                }
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
            armView.screenInk.clear()
            // Moving the full-screen windows to another size would show their old picture
            // stretched (and cut off at the old size) for a moment: hide them while they move and
            // fade them back in once they have drawn at the new size.
            let windows: [NSWindow] = [window, inkWindow] + whiteboard.windows
            windows.forEach { $0.alphaValue = 0 }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            whiteboard.show(on: screen.frame)
            window.setFrame(screen.frame, display: true)
            inkWindow.setFrame(screen.frame, display: true)
            armView.frame = NSRect(origin: .zero, size: screen.frame.size)
            CATransaction.commit()
            toolbar.place(on: screen)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                windows.forEach { $0.alphaValue = 1 }
            }
        }

        if mouse != lastMouse {
            lastMouse = mouse
            stillSince = Date()
        }

        updateZones(mouse: mouse, screen: screen)
        if let local = localMouse() {
            whiteboard.update(mouse: local)
        }
        let zoomFlags = Preferences.zoomKey.cgFlags
        let flags = HeldKeys.current
        let zoomKeyDown = !zoomFlags.isEmpty && flags.contains(zoomFlags)
        // Another modifier (not the zoom or adjust key) or any other key turns the flashlight and
        // loupe off at once, without fading, until the zoom key is pressed again: it may be a
        // screenshot shortcut such as ⇧⌘4.
        let allowed = zoomFlags.union(Preferences.loupeAdjustKey.cgFlags)
        let others = flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).subtracting(allowed)
        if !zoomKeyDown {
            zoomCancelled = false
        } else if !others.isEmpty || interactHeld {
            cancelZoom()
        }
        let zoomHeld = zoomKeyDown && !interactHeld && !zoomCancelled
        let adjustFlags = Preferences.loupeAdjustKey.cgFlags
        setAdjustingLoupe(zoomHeld && magnifier.isShowing && !adjustFlags.isEmpty
            && HeldKeys.current.contains(adjustFlags))
        if !zoomHeld {
            finishZoomDrag()
        }
        magnifier.update(held: zoomHeld, mouse: mouse, screen: screen)
        armView.hiddenForZoom = magnifier.isShowing
        inputTap.loupeShowing = magnifier.isShowing
        inputTap.hoveringStamp = localMouse().map { p in
            let (ink, q) = inkAndPoint(at: p)
            return ink.stamp(at: q) != nil
        } ?? false
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
            let busy = overDock || (!normalCursor && urgent) || CursorHider.isSettling || magnifier.isBusy || whiteboard.isAnimating
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
