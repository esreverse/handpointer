import AppKit

final class InputTap {
    var onMouseDown: (() -> Void)?
    var onInteractDown: (() -> Void)?
    var onInteractUp: (() -> Void)?
    var onMouseUp: (() -> Void)?
    var onLeftDragged: (() -> Void)?
    var onPassThroughPress: ((CGPoint) -> Void)?
    var onRightClickExit: (() -> Void)?
    /// Right-click on a capture rect (the toolbar's drag handle).
    var onCaptureRightClick: (() -> Void)?
    /// Scrolling while the zoom loupe is open, with the vertical scroll distance in points.
    /// Horizontal and vertical scroll distance while the loupe or flashlight is open.
    /// `began` is set on the first event of a trackpad swipe; momentum (coasting after lifting) is left out.
    var onLoupeScroll: ((CGFloat, CGFloat, ScrollPhase) -> Void)?
    private var swallowRightUp = false

    private let lock = NSLock()
    private var _active = false
    private var _passThroughRects: [CGRect] = []
    private var _captureRects: [CGRect] = []
    private var _rightExitRects: [CGRect] = []
    private var _interactKey: CGEventFlags = []
    private var _interactPress = false
    private var _rightClickExits = false
    private var _loupeShowing = false
    private var _hoveringStamp = false

    /// While the pointer is over a number stamp, the digit keys 1 to 9 renumber it.
    var hoveringStamp: Bool {
        get { lock.withLock { _hoveringStamp } }
        set { lock.withLock { _hoveringStamp = newValue } }
    }
    var onStampDigit: ((Int) -> Void)?
    /// A key went down while the flashlight or loupe was open (on the main queue).
    var onKeyWhileLoupe: (() -> Void)?

    private var _escExits = false
    /// While true, Esc (without modifiers) ends the session. Handled here rather than as a system
    /// hot key, which fails when another app (a screenshot tool, say) has already claimed Esc.
    var escExits: Bool {
        get { lock.withLock { _escExits } }
        set { lock.withLock { _escExits = newValue } }
    }
    var onEsc: (() -> Void)?

    private var _loupeAdjusting = false
    /// While the adjust key is held with the loupe open, mouse moves change size and zoom.
    var loupeAdjusting: Bool {
        get { lock.withLock { _loupeAdjusting } }
        set { lock.withLock { _loupeAdjusting = newValue } }
    }
    var onLoupeAdjust: ((CGFloat, CGFloat) -> Void)?

    /// While the loupe is open, scrolling resizes it instead of doing nothing.
    var loupeShowing: Bool {
        get { lock.withLock { _loupeShowing } }
        set { lock.withLock { _loupeShowing = newValue } }
    }

    /// A right click turns the pointer off instead of tapping.
    var rightClickExits: Bool {
        get { lock.withLock { _rightClickExits } }
        set { lock.withLock { _rightClickExits = newValue } }
    }

    var passThroughRects: [CGRect] {
        get { lock.withLock { _passThroughRects } }
        set { lock.withLock { _passThroughRects = newValue } }
    }

    /// Areas inside the pass-through rects whose clicks the overlay handles itself
    /// (the toolbar's drag handle), in the same CG coordinates.
    var captureRects: [CGRect] {
        get { lock.withLock { _captureRects } }
        set { lock.withLock { _captureRects = newValue } }
    }

    /// Pass-through areas where a right-click still turns the pointer off (the toolbar).
    var rightExitRects: [CGRect] {
        get { lock.withLock { _rightExitRects } }
        set { lock.withLock { _rightExitRects = newValue } }
    }

    private var active: Bool {
        lock.withLock { _active }
    }

    var interactKey: CGEventFlags {
        get { lock.withLock { _interactKey } }
        set { lock.withLock { _interactKey = newValue } }
    }

    var interactPressing: Bool {
        lock.withLock { _interactPress }
    }

    private var passingThrough = false
    private(set) var maxWaitMs: Double = 0
    private var tap: CFMachPort?
    /// A second, earlier tap (at the hardware level) only for scrolling while the flashlight or
    /// loupe is open: macOS's own features on modifier + scroll (Accessibility zoom on ⌃ + scroll)
    /// act before the normal tap would see the scroll, so it has to be caught earlier.
    private var scrollTap: CFMachPort?
    private var thread: Thread?

    private(set) var isInstalled = false

    @discardableResult
    func install() -> Bool {
        guard tap == nil else {
            return true
        }

        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.mouseMoved.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon = refcon else {
                    return Unmanaged.passUnretained(event)
                }
                let me = Unmanaged<InputTap>.fromOpaque(refcon).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            return false
        }
        CGEvent.tapEnable(tap: tap, enable: false)

        let scrollTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: 1 << CGEventType.scrollWheel.rawValue,
            callback: { _, type, event, refcon in
                guard let refcon = refcon else {
                    return Unmanaged.passUnretained(event)
                }
                let me = Unmanaged<InputTap>.fromOpaque(refcon).takeUnretainedValue()
                return me.handleEarlyScroll(type: type, event: event)
            },
            userInfo: refcon
        )
        if let scrollTap = scrollTap {
            CGEvent.tapEnable(tap: scrollTap, enable: false)
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let scrollSource = scrollTap.map { CFMachPortCreateRunLoopSource(kCFAllocatorDefault, $0, 0) }
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            if let scrollSource = scrollSource {
                CFRunLoopAddSource(CFRunLoopGetCurrent(), scrollSource, .commonModes)
            }
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "QuiteHandy event tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()

        self.tap = tap
        self.scrollTap = scrollTap
        self.thread = thread
        isInstalled = true
        return true
    }

    func setActive(_ value: Bool) {
        lock.withLock {
            _active = value
            _interactPress = false
        }
        HeldKeys.reset()
        if let scrollTap = scrollTap {
            CGEvent.tapEnable(tap: scrollTap, enable: value)
        }
        guard let tap = tap else {
            return
        }
        CGEvent.tapEnable(tap: tap, enable: value)
    }

    /// Scrolling while the flashlight or loupe is open goes to it and nowhere else, caught before
    /// macOS can use it for its own zoom. Everything else passes on to the normal tap.
    private func handleEarlyScroll(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if active, let t = scrollTap {
                CGEvent.tapEnable(tap: t, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        guard type == .scrollWheel, active, loupeShowing else {
            return Unmanaged.passUnretained(event)
        }
        let (dx, dy) = InputTap.fingerDeltas(event)
        let phase = ScrollPhase(raw: event.getIntegerValueField(.scrollWheelEventScrollPhase))
        if event.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0 {
            DispatchQueue.main.async { [weak self] in self?.onLoupeScroll?(dx, dy, phase) }
        }
        return nil
    }

    func simulate(_ type: CGEventType) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: .left) else {
            return
        }
        let was = active
        lock.withLock { _active = true }
        _ = handle(type: type, event: event)
        lock.withLock { _active = was }
    }

    func resetWait() {
        maxWaitMs = 0
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if event.timestamp > 0 {
            let wait = Double(DispatchTime.now().uptimeNanoseconds &- event.timestamp) / 1_000_000
            if wait < 600_000 {
                maxWaitMs = max(maxWaitMs, wait)
            }
        }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if type == .tapDisabledByTimeout {
                Log.write("event tap was disabled by a timeout; re-enabled")
            }
            if active, let tap = tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard active else {
            return Unmanaged.passUnretained(event)
        }

        // Space and Tab set as hold keys: remember whether they are down and keep them from the
        // app underneath. With ⌘, ⌃ or ⌥, Tab stays Tab (⌃⇥ turns the pointer off, ⌘⇥ switches apps).
        if type == .keyDown || type == .keyUp {
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if let flag = HeldKeys.flag(forKeyCode: code) {
                let down = type == .keyDown
                let chord = !event.flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty
                if down && chord && !HeldKeys.isHeld(flag) {
                    return Unmanaged.passUnretained(event)
                }
                if !down && !HeldKeys.isHeld(flag) {
                    return Unmanaged.passUnretained(event)
                }
                HeldKeys.set(flag, down: down)
                return nil
            }
            if type == .keyUp {
                return Unmanaged.passUnretained(event)
            }
        }

        if type == .mouseMoved {
            if loupeAdjusting {
                let dx = CGFloat(event.getDoubleValueField(.mouseEventDeltaX))
                let dy = CGFloat(event.getDoubleValueField(.mouseEventDeltaY))
                DispatchQueue.main.async { [weak self] in self?.onLoupeAdjust?(dx, dy) }
            }
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 53, escExits,
           event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty {
            DispatchQueue.main.async { [weak self] in self?.onEsc?() }
            return nil
        }
        if type == .keyDown {
            // Any other key while the flashlight or loupe is open turns it off at once (it might
            // be a screenshot shortcut, and the screenshot must not show the darkening).
            if loupeShowing {
                DispatchQueue.main.async { [weak self] in self?.onKeyWhileLoupe?() }
            }
            let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate]
            if hoveringStamp, event.flags.intersection(modifiers).isEmpty,
               let digit = InputTap.digit(for: event.getIntegerValueField(.keyboardEventKeycode)) {
                DispatchQueue.main.async { [weak self] in self?.onStampDigit?(digit) }
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        let key = interactKey
        // Scrolling only reaches your Mac while the interact key is held; with the loupe open
        // it changes the loupe's size, otherwise it does nothing.
        if type == .scrollWheel {
            if !key.isEmpty && (event.flags.contains(key) || HeldKeys.current.contains(key)) {
                event.flags.remove(key)
                return Unmanaged.passUnretained(event)
            }
            if loupeShowing {
                let (dx, dy) = InputTap.fingerDeltas(event)
                let phase = ScrollPhase(raw: event.getIntegerValueField(.scrollWheelEventScrollPhase))
                if event.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0 {
                    DispatchQueue.main.async { [weak self] in self?.onLoupeScroll?(dx, dy, phase) }
                }
            }
            return nil
        }
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if !key.isEmpty && (event.flags.contains(key) || HeldKeys.current.contains(key)) {
                lock.withLock { _interactPress = true }
                DispatchQueue.main.async { [weak self] in self?.onInteractDown?() }
            }
        default:
            break
        }
        if lock.withLock({ _interactPress }) {
            event.flags.remove(key)
            if type == .leftMouseUp || type == .rightMouseUp || type == .otherMouseUp {
                lock.withLock { _interactPress = false }
                DispatchQueue.main.async { [weak self] in self?.onInteractUp?() }
            }
            return Unmanaged.passUnretained(event)
        }

        // Right-click on the toolbar (but not its drag handle) ends the session like elsewhere.
        if type == .rightMouseDown, rightClickExits,
           rightExitRects.contains(where: { $0.contains(event.location) }),
           !captureRects.contains(where: { $0.contains(event.location) }) {
            swallowRightUp = true
            DispatchQueue.main.async { [weak self] in self?.onRightClickExit?() }
            return nil
        }
        if type == .rightMouseUp, swallowRightUp {
            swallowRightUp = false
            return nil
        }

        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            passingThrough = passThroughRects.contains { $0.contains(event.location) }
                && !captureRects.contains { $0.contains(event.location) }
            if passingThrough {
                let location = event.location
                DispatchQueue.main.async { [weak self] in self?.onPassThroughPress?(location) }
            }
        default:
            break
        }
        if passingThrough {
            if type == .leftMouseUp || type == .rightMouseUp || type == .otherMouseUp {
                passingThrough = false
            }
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .rightMouseDown where captureRects.contains { $0.contains(event.location) }:
            // Right-click on the drag handle only resets the toolbar; it never ends the session.
            swallowRightUp = true
            DispatchQueue.main.async { [weak self] in self?.onCaptureRightClick?() }
            return nil
        case .rightMouseUp where swallowRightUp:
            swallowRightUp = false
            return nil
        case .rightMouseDown where rightClickExits:
            DispatchQueue.main.async { [weak self] in self?.onRightClickExit?() }
            return nil
        case .rightMouseUp where rightClickExits:
            return nil
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            DispatchQueue.main.async { [weak self] in self?.onMouseDown?() }
            return nil
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            DispatchQueue.main.async { [weak self] in self?.onMouseUp?() }
            return nil
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            if type == .leftMouseDragged {
                DispatchQueue.main.async { [weak self] in self?.onLeftDragged?() }
            }
            event.type = .mouseMoved
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}

extension InputTap {
    /// Scroll distances as macOS delivers them (after the system's and any mouse software's
    /// own direction settings).
    static func fingerDeltas(_ event: CGEvent) -> (dx: CGFloat, dy: CGFloat) {
        (CGFloat(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)),
         CGFloat(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)))
    }

    /// 1 to 9 for the digit keys of the main row and the keypad.
    static func digit(for keyCode: Int64) -> Int? {
        let row: [Int64: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
        let pad: [Int64: Int] = [83: 1, 84: 2, 85: 3, 86: 4, 87: 5, 88: 6, 89: 7, 91: 8, 92: 9]
        return row[keyCode] ?? pad[keyCode]
    }
}

/// Where a scroll event is in a trackpad swipe. Mouse wheels have no phases (`.wheel`).
enum ScrollPhase {
    case began, changed, ended, wheel

    init(raw: Int64) {
        switch raw {
        case 1, 128: self = .began
        case 4, 8: self = .ended
        case 0: self = .wheel
        default: self = .changed
        }
    }
}
