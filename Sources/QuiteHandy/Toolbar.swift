import AppKit

final class Toolbar {
    var onPick: ((PointerStyle) -> Void)?
    var onToggleSound: (() -> Void)?
    var onExit: (() -> Void)?
    var onFixPermission: (() -> Void)?
    /// The colour the next line will have (rainbow: where the last one ended), for the color pointer's icon.
    var currentInkColor: (() -> CGColor)?

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private final class Button: NSButton {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    /// A small turning knob: drag up to turn it right (more), down to turn it left (less). The value
    /// is read at a fixed white dot at 12 o'clock: the opacity knob is a disc going from clear to
    /// solid white around it, the size knob a snail whose radius grows around it.
    final class Knob: NSView {
        private let unit: String
        private let range: ClosedRange<Int>
        /// Points of mouse travel per step.
        private let pointsPerStep: CGFloat
        private let get: () -> Int
        private let set: (Int) -> Void
        private var dragStart: (y: CGFloat, value: Int)?
        var onChange: (() -> Void)?
        /// True while it is being turned, so the toolbar stays out even if the pointer leaves it.
        private(set) var isDragging = false

        init(unit: String, range: ClosedRange<Int>, pointsPerStep: CGFloat, get: @escaping () -> Int, set: @escaping (Int) -> Void) {
            self.unit = unit
            self.range = range
            self.pointsPerStep = pointsPerStep
            self.get = get
            self.set = set
            super.init(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
            translatesAutoresizingMaskIntoConstraints = false
            widthAnchor.constraint(equalToConstant: 40).isActive = true
            heightAnchor.constraint(equalToConstant: 40).isActive = true
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) not used")
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        /// Where the value sits between the least (0) and the most (1).
        private var fraction: CGFloat {
            CGFloat(get() - range.lowerBound) / CGFloat(max(1, range.upperBound - range.lowerBound))
        }

        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else {
                return
            }
            let c = CGPoint(x: bounds.midX, y: bounds.midY - 2)
            let rMax: CGFloat = 10
            // The fixed reading mark: a small white dot just outside the knob at 12 o'clock.
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: CGRect(x: c.x - 1.25, y: c.y + rMax + 3, width: 2.5, height: 2.5))

            // The knob turns clockwise as the value grows; what is at 12 o'clock is the value.
            // Around the knob (counter-clockwise from the top, before turning) the value grows
            // from the least to the most.
            ctx.saveGState()
            ctx.translateBy(x: c.x, y: c.y)
            ctx.rotate(by: -fraction * 2 * .pi)
            let steps = 120
            // The size knob's snail sits on a 20 % black disc; the opacity knob has no background.
            if unit != "%" {
                ctx.setFillColor(NSColor(white: 0, alpha: 0.2).cgColor)
                ctx.fillEllipse(in: CGRect(x: -rMax, y: -rMax, width: 2 * rMax, height: 2 * rMax))
            }
            if unit != "%" {
                // Size: a white snail whose radius grows around it, solid at its small end and
                // dimmer towards its large end.
                for i in 0..<steps {
                    let t0 = CGFloat(i) / CGFloat(steps)
                    let t1 = CGFloat(i + 1) / CGFloat(steps)
                    let a0 = .pi / 2 + t0 * 2 * .pi
                    // A hair of overlap so no seams show between the slices.
                    let a1 = .pi / 2 + t1 * 2 * .pi + 0.01
                    let r0 = 3 + (rMax - 3) * t0
                    let r1 = 3 + (rMax - 3) * t1
                    let slice = CGMutablePath()
                    slice.move(to: .zero)
                    slice.addLine(to: CGPoint(x: cos(a0) * r0, y: sin(a0) * r0))
                    slice.addLine(to: CGPoint(x: cos(a1) * r1, y: sin(a1) * r1))
                    slice.closeSubpath()
                    ctx.setFillColor(NSColor(white: 1, alpha: 1 - 0.45 * t0).cgColor)
                    ctx.addPath(slice)
                    ctx.fillPath()
                }
                ctx.restoreGState()
                return
            }
            for i in 0..<steps {
                let t0 = CGFloat(i) / CGFloat(steps)
                let t1 = CGFloat(i + 1) / CGFloat(steps)
                // Angles from 12 o'clock, counter-clockwise.
                let a0 = .pi / 2 + t0 * 2 * .pi
                let a1 = .pi / 2 + t1 * 2 * .pi
                let wedge = CGMutablePath()
                wedge.move(to: .zero)
                if unit == "%" {
                    // Opacity: a full disc whose white goes from clear to solid around it.
                    wedge.addArc(center: .zero, radius: rMax, startAngle: a0, endAngle: a1 + 0.01, clockwise: false)
                    ctx.setFillColor(NSColor(white: 1, alpha: t0).cgColor)
                } else {
                    // Size: a snail whose radius grows from small to large around it.
                    let r0 = 3 + (rMax - 3) * t0
                    let r1 = 3 + (rMax - 3) * t1
                    wedge.addLine(to: CGPoint(x: cos(a0) * r0, y: sin(a0) * r0))
                    wedge.addLine(to: CGPoint(x: cos(a1) * r1, y: sin(a1) * r1))
                    ctx.setFillColor(NSColor.white.cgColor)
                }
                wedge.closeSubpath()
                ctx.addPath(wedge)
                ctx.fillPath()
            }
            ctx.restoreGState()
        }

        override func mouseDown(with event: NSEvent) {
            dragStart = (NSEvent.mouseLocation.y, get())
            isDragging = true
            needsDisplay = true
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = dragStart else {
                return
            }
            let steps = Int(((NSEvent.mouseLocation.y - start.y) / pointsPerStep).rounded())
            let value = min(range.upperBound, max(range.lowerBound, start.value + steps))
            if value != get() {
                set(value)
                onChange?()
            }
            needsDisplay = true
        }

        override func mouseUp(with event: NSEvent) {
            dragStart = nil
            isDragging = false
            needsDisplay = true
        }

        func refresh() {
            needsDisplay = true
        }
    }

    /// Grip on the left end: drag to move the toolbar, right-click to put it back.
    private final class Handle: NSView {
        var onMoved: (() -> Void)?
        var onReset: (() -> Void)?
        private var start: CGPoint?
        private var startOrigin: CGPoint?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            NSColor(white: 1, alpha: 0.45).setFill()
            for col in 0..<2 {
                for row in 0..<3 {
                    let x = bounds.midX - 2.25 + CGFloat(col) * 4.5 - 1.25
                    let y = bounds.midY - 4.5 + CGFloat(row) * 4.5 - 1.25
                    NSBezierPath(ovalIn: CGRect(x: x, y: y, width: 2.5, height: 2.5)).fill()
                }
            }
        }

        override func mouseDown(with event: NSEvent) {
            start = NSEvent.mouseLocation
            startOrigin = window?.frame.origin
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = start, let origin = startOrigin, let window = window else {
                return
            }
            let now = NSEvent.mouseLocation
            window.setFrameOrigin(CGPoint(x: origin.x + now.x - start.x, y: origin.y + now.y - start.y))
        }

        override func mouseUp(with event: NSEvent) {
            if start != nil {
                onMoved?()
            }
            start = nil
            startOrigin = nil
        }

        override func rightMouseDown(with event: NSEvent) {
            onReset?()
        }
    }

    private let panel: Panel
    private let stack = NSStackView()
    private var styleButtons: [PointerStyle: Button] = [:]
    private var shownStyles: [PointerStyle] = []
    private var current: PointerStyle?
    private var inkButton: Button?
    private var swatches: [InkChoice: Button] = [:]
    private var knobs: [Knob] = []
    /// The toolbar's window, to leave it out of screenshots.
    var windowNumber: Int { panel.windowNumber }
    /// The line between the knobs and the colours.
    private var knobDivider: NSView?
    /// True while a knob is being turned: the toolbar stays out until the mouse goes up.
    var isAdjusting: Bool { knobs.contains { $0.isDragging } }

    private func refreshKnobTips() {
        guard knobs.count == 2 else {
            return
        }
        tips[knobs[0]] = "Opacity \(Preferences.inkOpacity)% (drag up/down)"
        tips[knobs[1]] = "Size \(Preferences.strokeSize) pt (drag up/down)"
        knobs.forEach { $0.refresh() }
    }
    private var inkDivider: NSView?
    private var inkOpen = false
    private let permissionButton = Button()
    private var soundButton: Button?
    private(set) var revealed = false

    private let tray: Panel
    private let trayStack = NSStackView()
    private var hint: Panel?

    var frame: CGRect { inkOpen ? panel.frame.union(tray.frame) : panel.frame }

    init() {
        panel = Panel(contentRect: CGRect(x: 0, y: 0, width: 300, height: 56),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.alphaValue = 0

        let (glass, background) = Glass.make(radius: 20)
        panel.contentView = glass

        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])

        tray = Panel(contentRect: CGRect(x: 0, y: 0, width: 200, height: 40),
                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        tray.isOpaque = false
        tray.backgroundColor = .clear
        tray.hasShadow = true
        tray.hidesOnDeactivate = false
        tray.isFloatingPanel = true
        tray.becomesKeyOnlyIfNeeded = true
        tray.level = panel.level
        tray.collectionBehavior = panel.collectionBehavior
        tray.alphaValue = 0
        let (trayGlass, trayBackground) = Glass.make(radius: 14)
        tray.contentView = trayGlass
        trayStack.orientation = .horizontal
        trayStack.spacing = 2
        trayStack.edgeInsets = NSEdgeInsets(top: 5, left: 6, bottom: 5, right: 6)
        trayStack.translatesAutoresizingMaskIntoConstraints = false
        trayBackground.addSubview(trayStack)
        NSLayoutConstraint.activate([
            trayStack.leadingAnchor.constraint(equalTo: trayBackground.leadingAnchor),
            trayStack.trailingAnchor.constraint(equalTo: trayBackground.trailingAnchor),
            trayStack.topAnchor.constraint(equalTo: trayBackground.topAnchor),
            trayStack.bottomAnchor.constraint(equalTo: trayBackground.bottomAnchor),
        ])

        let handle = Handle()
        tips[handle] = "Drag to move, right-click to reset"
        handle.translatesAutoresizingMaskIntoConstraints = false
        handle.widthAnchor.constraint(equalToConstant: 28).isActive = true
        handle.heightAnchor.constraint(equalToConstant: 40).isActive = true
        handle.onMoved = { [weak self] in self?.savePosition() }
        handle.onReset = { [weak self] in self?.resetPosition() }
        stack.insertArrangedSubview(handle, at: 0)
        stack.setCustomSpacing(12, after: handle)
        handleView = handle

        stack.addArrangedSubview(Toolbar.divider())
        // Two knobs left of the colours: opacity in %, stroke size in pt.
        let opacityKnob = Knob(unit: "%", range: 10...100, pointsPerStep: 2,
                               get: { Preferences.inkOpacity }, set: { Preferences.inkOpacity = $0 })
        let sizeKnob = Knob(unit: "pt", range: Preferences.strokeSizeRange, pointsPerStep: 3,
                            get: { Preferences.strokeSize }, set: { Preferences.strokeSize = $0 })
        for k in [opacityKnob, sizeKnob] {
            // The simple cursor in the toolbar follows the knobs live.
            k.onChange = { [weak self] in self?.refreshInk() }
            stack.addArrangedSubview(k)
            knobs.append(k)
        }
        let knobDivider = Toolbar.divider()
        self.knobDivider = knobDivider
        stack.addArrangedSubview(knobDivider)
        refreshKnobTips()
        // Ink colours sit right in the toolbar, one button each, instead of in a pop-up tray.
        for choice in InkChoice.allCases {
            let b = makeButton(image: nil, tip: choice.title) {
                Preferences.inkChoice = choice
            }
            swatches[choice] = b
            stack.addArrangedSubview(b)
        }
        let divider = Toolbar.divider()
        inkDivider = divider
        stack.addArrangedSubview(divider)
        // No sound button in the toolbar: sound is toggled with its shortcut, the menu or Settings.
        stack.addArrangedSubview(makeButton(symbol: "xmark", tip: "Exit (Esc)") { [weak self] in
            self?.onExit?()
        })

        permissionButton.bezelStyle = .rounded
        permissionButton.isBordered = false
        permissionButton.wantsLayer = true
        permissionButton.layer?.cornerRadius = 10
        permissionButton.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.9).cgColor
        permissionButton.attributedTitle = NSAttributedString(string: "  Allow clicks & drawing  ", attributes: [
            .foregroundColor: NSColor.black,
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
        ])
        permissionButton.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        permissionButton.imagePosition = .imageLeading
        permissionButton.contentTintColor = .black
        permissionButton.toolTip = "Quite Handy needs Accessibility permission to intercept clicks and draw"
        permissionButton.heightAnchor.constraint(equalToConstant: 32).isActive = true
        permissionButton.target = self
        permissionButton.action = #selector(fixPermission)
        permissionButton.isHidden = true
        stack.addArrangedSubview(permissionButton)

        rebuildStyles()
        background.removeFocusRings()
        resize()
        refreshInk()
        NotificationCenter.default.addObserver(forName: Preferences.changed, object: nil, queue: .main) { [weak self] _ in
            self?.rebuildStyles()
            self?.refreshInk()
        }
    }

    private func toggleInk() {
        setInkOpen(!inkOpen)
    }

    private func setInkOpen(_ open: Bool) {
        guard open != inkOpen, let ink = inkButton else {
            return
        }
        inkOpen = open
        if open {
            if swatches.isEmpty {
                for choice in InkChoice.allCases {
                    let b = makeButton(image: nil, tip: choice.title, side: 30) { [weak self] in
                        Preferences.inkChoice = choice
                        self?.setInkOpen(false)
                    }
                    b.layer?.cornerRadius = 15
                    swatches[choice] = b
                    trayStack.addArrangedSubview(b)
                }
                tray.contentView?.removeFocusRings()
                trayStack.layoutSubtreeIfNeeded()
                tray.setContentSize(trayStack.fittingSize)
            }
            refreshInk()
            let r = panel.convertToScreen(ink.convert(ink.bounds, to: nil))
            let size = tray.frame.size
            tray.setFrameOrigin(CGPoint(x: r.midX - size.width / 2, y: panel.frame.maxY + 8))
            tray.invalidateShadow()
            tray.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                tray.animator().alphaValue = 1
            }
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                tray.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self = self, !self.inkOpen else {
                    return
                }
                self.tray.orderOut(nil)
            })
        }
        refreshInk()
    }

    func refreshInk() {
        let color = currentInkColor?() ?? Ink.hex(0xFFFFFF)
        if let b = styleButtons[.stroke] {
            b.image = Toolbar.padded(Toolbar.colorPointerIcon(color))
        }
        let hidden = !Preferences.showInkButton
        var changed = false
        for (choice, b) in swatches {
            b.image = choice == .rainbow ? Toolbar.rainbowDot() : choice.color.map(Toolbar.inkDot) ?? Toolbar.autoDot()
            b.layer?.backgroundColor = choice == Preferences.inkChoice ? Toolbar.selectedColor
                : (b === hovered ? Toolbar.hoverColor : NSColor.clear.cgColor)
            if b.isHidden != hidden {
                b.isHidden = hidden
                changed = true
            }
        }
        let knobsHidden = !Preferences.showKnobs
        for k in knobs where k.isHidden != knobsHidden {
            k.isHidden = knobsHidden
            changed = true
        }
        if let d = knobDivider, d.isHidden != knobsHidden {
            d.isHidden = knobsHidden
            changed = true
        }
        refreshKnobTips()
        if let divider = inkDivider, divider.isHidden != hidden {
            divider.isHidden = hidden
            changed = true
        }
        if changed {
            resizeKeepingCenter()
        }
    }

    private func resizeKeepingCenter() {
        let center = CGPoint(x: panel.frame.midX, y: panel.frame.minY)
        resize()
        panel.setFrameOrigin(CGPoint(x: center.x - panel.frame.width / 2, y: center.y))
    }

    private func rebuildStyles() {
        var styles = PointerStyle.toolbarStyles
        if let c = current, !styles.contains(c) {
            styles.insert(c, at: styles.count - 1)
        }
        if styles == shownStyles {
            return
        }
        shownStyles = styles
        for b in styleButtons.values {
            actions[b] = nil
            tips[b] = nil
            b.removeFromSuperview()
        }
        styleButtons = [:]
        for (i, style) in styles.enumerated() {
            // Hands are named "… cursor" in the tooltip.
            let tip = style.assetName != nil ? "\(style.title) cursor" : style.title
            let b = makeButton(image: Toolbar.padded(Toolbar.icon(for: style)), tip: tip) { [weak self] in
                self?.onPick?(style)
            }
            styleButtons[style] = b
            stack.insertArrangedSubview(b, at: i + 1)  // after the drag handle
        }
        if let c = current {
            highlight(c)
        }
        refreshInk()
        resizeKeepingCenter()
    }

    func setSoundOn(_ on: Bool) {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let name = on ? "speaker.wave.2.fill" : "speaker.slash.fill"
        let tip = (on ? "Sound on, click to mute" : "Sound off, click to unmute") + " (\(Preferences.soundShortcut.display))"
        soundButton?.image = NSImage(systemSymbolName: name, accessibilityDescription: tip)?.withSymbolConfiguration(config)
        if let b = soundButton {
            tips[b] = tip
        }
        soundButton?.contentTintColor = NSColor(white: 1, alpha: on ? 0.85 : 0.45)
    }

    func center(of style: PointerStyle) -> CGPoint? {
        guard let b = styleButtons[style], let w = b.window else {
            return nil
        }
        let r = w.convertToScreen(b.convert(b.bounds, to: nil))
        return CGPoint(x: r.midX, y: r.midY)
    }

    func snapshot() -> NSBitmapImageRep? {
        guard let view = panel.contentView else {
            return nil
        }
        view.layer?.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        view.layer?.backgroundColor = nil
        return rep
    }

    func snapshotInkTray() -> NSBitmapImageRep? {
        setInkOpen(true)
        guard let view = tray.contentView else {
            return nil
        }
        view.layer?.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    func showHint(_ parts: [(key: String, text: String)]) {
        hideHint()
        let p = Panel(contentRect: CGRect(x: 0, y: 0, width: 300, height: 36),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.level = panel.level
        p.collectionBehavior = panel.collectionBehavior
        p.alphaValue = 0
        let (hintGlass, bg) = Glass.make(radius: 12)
        p.contentView = hintGlass
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 14
        row.edgeInsets = NSEdgeInsets(top: 9, left: 16, bottom: 9, right: 16)
        row.translatesAutoresizingMaskIntoConstraints = false
        for part in parts {
            let text = NSMutableAttributedString(string: part.key, attributes: [
                .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
                .foregroundColor: NSColor.white,
            ])
            text.append(NSAttributedString(string: " " + part.text, attributes: [
                .font: NSFont.systemFont(ofSize: 12.5),
                .foregroundColor: NSColor(white: 1, alpha: 0.7),
            ]))
            row.addArrangedSubview(NSTextField(labelWithAttributedString: text))
        }
        bg.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            row.topAnchor.constraint(equalTo: bg.topAnchor),
            row.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
        ])
        row.layoutSubtreeIfNeeded()
        p.setContentSize(row.fittingSize)
        p.setFrameOrigin(CGPoint(x: panel.frame.midX - p.frame.width / 2, y: panel.frame.maxY + 12))
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            p.animator().alphaValue = 1
        }
        hint = p
    }

    func snapshotHint() -> NSBitmapImageRep? {
        guard let view = hint?.contentView else {
            return nil
        }
        view.layer?.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    func hideHint() {
        guard let p = hint else {
            return
        }
        hint = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            p.animator().alphaValue = 0
        }, completionHandler: {
            p.orderOut(nil)
        })
    }

    func select(_ style: PointerStyle) {
        current = style
        rebuildStyles()
        highlight(style)
        refreshInk()
    }

    private func highlight(_ style: PointerStyle) {
        for (s, b) in styleButtons {
            b.layer?.backgroundColor = s == style ? Toolbar.selectedColor
                : (b === hovered ? Toolbar.hoverColor : NSColor.clear.cgColor)
        }
    }

    func setNeedsPermission(_ needed: Bool) {
        guard permissionButton.isHidden == needed else {
            return
        }
        permissionButton.isHidden = !needed
        let center = CGPoint(x: panel.frame.midX, y: panel.frame.minY)
        resize()
        panel.setFrameOrigin(CGPoint(x: center.x - panel.frame.width / 2, y: center.y))
    }

    private weak var placedScreen: NSScreen?
    private weak var handleView: NSView?

    // Own tooltips: the native ones never show while QuiteHandy runs in the background
    // with the cursor hidden, so the overlay tells the toolbar where the mouse is.
    private var tips: [NSView: String] = [:]
    private var tipPanel: Panel?

    private let tipLabel = NSTextField(labelWithString: "")
    private var tipContent: NSView?
    private weak var hovered: NSView?
    private var hoverSince = Date.distantPast
    private static let tipDelay: TimeInterval = 0.5

    private func tipText(for view: NSView) -> String? {
        if let choice = swatches.first(where: { $0.value === view })?.key {
            switch choice {
            case .rainbow: return "Rainbow (\(Preferences.rainbowInkShortcut.display))"
            case .match: return "Automatic colour, matches the pointer (\(Preferences.matchInkShortcut.display))"
            default: return choice.title
            }
        }
        return tips[view]
    }

    /// Call on every overlay tick with the mouse in screen coordinates.
    func updateHover(mouse: CGPoint) {
        // While a knob is turned its tooltip stays up and shows the value as it changes.
        if let k = knobs.first(where: { $0.isDragging }), let text = tips[k] {
            if hovered !== k {
                hovered = k
                showHover(on: k)
            }
            showTip(text, over: k)
            return
        }
        let view = revealed ? tips.keys.first { v in
            guard !v.isHidden, v.window === panel else {
                return false
            }
            return panel.convertToScreen(v.convert(v.bounds, to: nil)).contains(mouse)
        } : nil
        if view !== hovered {
            hovered = view
            hoverSince = Date()
            hideTip()
            showHover(on: view)
        }
        guard let v = view, dragStart == nil, tipPanel?.isVisible != true,
              Date().timeIntervalSince(hoverSince) >= Toolbar.tipDelay,
              let text = tipText(for: v) else {
            return
        }
        showTip(text, over: v)
    }

    private func showTip(_ text: String, over view: NSView) {
        let p: Panel
        if let existing = tipPanel {
            p = existing
        } else {
            p = Panel(contentRect: CGRect(x: 0, y: 0, width: 100, height: 24),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.ignoresMouseEvents = true
            p.level = panel.level
            p.collectionBehavior = panel.collectionBehavior
            // Tooltips only fade in: no zoom or slide from macOS.
            p.animationBehavior = .none
            let (tipGlass, bg) = Glass.make(radius: 8)
            p.contentView = tipGlass
            tipContent = bg
            tipLabel.font = NSFont.systemFont(ofSize: 12)
            tipLabel.textColor = .white
            tipLabel.translatesAutoresizingMaskIntoConstraints = false
            bg.addSubview(tipLabel)
            NSLayoutConstraint.activate([
                tipLabel.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 10),
                tipLabel.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -10),
                tipLabel.topAnchor.constraint(equalTo: bg.topAnchor, constant: 5),
                tipLabel.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -5),
            ])
            tipPanel = p
        }
        tipLabel.stringValue = text
        tipContent?.layoutSubtreeIfNeeded()
        p.setContentSize(tipContent?.fittingSize ?? CGSize(width: 100, height: 24))
        let r = panel.convertToScreen(view.convert(view.bounds, to: nil))
        p.setFrameOrigin(CGPoint(x: r.midX - p.frame.width / 2, y: panel.frame.maxY + 6))
        p.invalidateShadow()
        if !p.isVisible {
            p.alphaValue = 0
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                p.animator().alphaValue = 1
            }
        }
    }

    private static let hoverColor = NSColor(white: 1, alpha: 0.1).cgColor
    private static let selectedColor = NSColor(white: 1, alpha: 0.2).cgColor

    /// Paints the hovered item's own background (the glass would cover anything behind it);
    /// the selected item keeps its stronger fill.
    private func showHover(on view: NSView?) {
        for v in tips.keys where v !== view {
            if v.layer?.backgroundColor == Toolbar.hoverColor {
                v.layer?.backgroundColor = NSColor.clear.cgColor
            }
        }
        guard let v = view else {
            return
        }
        v.wantsLayer = true
        v.layer?.cornerRadius = 10
        let current = v.layer?.backgroundColor
        if current == nil || current?.alpha == 0 {
            v.layer?.backgroundColor = Toolbar.hoverColor
        }
    }

    private func hideTip() {
        tipPanel?.orderOut(nil)
    }
    private var dragStart: (mouse: CGPoint, origin: CGPoint)?

    /// The drag handle in screen coordinates, a little larger than drawn so it is easy to grab.
    var handleFrame: CGRect? {
        guard revealed, let h = handleView, let w = h.window else {
            return nil
        }
        return w.convertToScreen(h.convert(h.bounds, to: nil)).insetBy(dx: -6, dy: -4)
    }

    /// Dragging driven by the overlay, which sees the clicks even when they never reach the panel.
    func startDrag(at mouse: CGPoint) {
        dragStart = (mouse, panel.frame.origin)
        hideTip()
    }

    func continueDrag(to mouse: CGPoint) {
        guard let d = dragStart else {
            return
        }
        panel.setFrameOrigin(CGPoint(x: d.origin.x + mouse.x - d.mouse.x, y: d.origin.y + mouse.y - d.mouse.y))
    }

    func endDrag() {
        if dragStart != nil {
            savePosition()
        }
        dragStart = nil
    }

    func place(on screen: NSScreen) {
        setInkOpen(false)
        placedScreen = screen
        let f = panel.frame
        let s = screen.frame
        if let p = Preferences.toolbarPosition {
            // Where the user dragged it, kept on screen.
            let x = min(max(s.minX + p.x - f.width / 2, s.minX), s.maxX - f.width)
            let y = min(max(s.minY + p.y, s.minY), s.maxY - f.height)
            panel.setFrameOrigin(CGPoint(x: x, y: y))
            return
        }
        // Keep clear of the Dock, also when it hides itself and only slides in near the bottom edge.
        let base = max(screen.visibleFrame.minY, s.minY + 80)
        panel.setFrameOrigin(CGPoint(x: s.midX - f.width / 2, y: base + 16))
    }

    private func savePosition() {
        guard let screen = placedScreen ?? panel.screen else {
            return
        }
        let f = panel.frame
        Preferences.toolbarPosition = CGPoint(x: f.midX - screen.frame.minX, y: f.minY - screen.frame.minY)
    }

    func resetPosition() {
        Preferences.toolbarPosition = nil
        if let screen = placedScreen ?? panel.screen {
            place(on: screen)
        }
    }

    func show() {
        // Only our own fade: no zoom-in from macOS when the panel appears.
        panel.animationBehavior = .none
        if !revealed {
            panel.alphaValue = 0
        }
        panel.orderFrontRegardless()
        panel.invalidateShadow()
    }

    func hide() {
        hideTip()
        setInkOpen(false)
        hideHint()
        revealed = false
        panel.alphaValue = 0
        panel.orderOut(nil)
    }

    func setRevealed(_ value: Bool, animated: Bool = true) {
        guard value != revealed else {
            return
        }
        revealed = value
        if !value {
            setInkOpen(false)
            hideTip()
            hovered = nil
            showHover(on: nil)
        }
        panel.ignoresMouseEvents = !value
        guard animated else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0
                panel.animator().alphaValue = value ? 1 : 0
            }
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            // Fades in over 0.3 s (like the toolbar on the website), out over 0.35 s.
            ctx.duration = value ? 0.3 : 0.35
            panel.animator().alphaValue = value ? 1 : 0
        }
    }

    private func resize() {
        stack.layoutSubtreeIfNeeded()
        let size = stack.fittingSize
        panel.setContentSize(size)
        panel.invalidateShadow()
    }

    private var actions: [Button: () -> Void] = [:]

    private func makeButton(image: NSImage? = nil, symbol: String? = nil, tip: String, side: CGFloat = 40, action: @escaping () -> Void) -> Button {
        let b = Button()
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.imageScaling = .scaleProportionallyUpOrDown
        tips[b] = tip
        b.setAccessibilityLabel(tip)
        b.wantsLayer = true
        b.layer?.cornerRadius = 10
        if let image = image {
            b.image = image
        }
        if let symbol = symbol {
            let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?.withSymbolConfiguration(config)
            b.contentTintColor = NSColor(white: 1, alpha: 0.85)
            b.imageScaling = .scaleNone
        }
        b.widthAnchor.constraint(equalToConstant: side).isActive = true
        b.heightAnchor.constraint(equalToConstant: side).isActive = true
        b.target = self
        b.action = #selector(tapped(_:))
        actions[b] = action
        return b
    }

    @objc private func tapped(_ sender: Button) {
        actions[sender]?()
    }

    @objc private func fixPermission() {
        onFixPermission?()
    }

    private static func inkDot(_ color: CGColor) -> NSImage {
        NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let r: CGFloat = 13
            (NSColor(cgColor: color) ?? .white).setFill()
            NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)).fill()
            Toolbar.strokeOutline(center: c, radius: r)
            return true
        }
    }

    /// A bold "A" as a shape, centred on its own outline at `center` and `height` tall. Drawn as
    /// a shape it never snaps to a pixel row, so it stays put on 1× screens as the size changes.
    static func letterA(center c: CGPoint, height: CGFloat) -> CGPath {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 100, nil)
        var unichar: UniChar = 65  // "A"
        var glyph = CGGlyph()
        CTFontGetGlyphsForCharacters(font, &unichar, &glyph, 1)
        guard let path = CTFontCreatePathForGlyph(font, glyph, nil) else {
            return CGMutablePath()
        }
        let box = path.boundingBoxOfPath
        let k = height / box.height
        var t = CGAffineTransform(translationX: c.x, y: c.y)
            .scaledBy(x: k, y: k)
            .translatedBy(x: -box.midX, y: -box.midY)
        return path.copy(using: &t) ?? CGMutablePath()
    }

    /// The thin light ring every dot in the toolbar has, so dark colours show on the dark bar.
    /// `width` is in image points; the dots are drawn at 64 and shown at 40.
    private static func strokeOutline(center c: CGPoint, radius r: CGFloat, width: CGFloat = 1) {
        NSColor(white: 1, alpha: 0.3).setStroke()
        let outline = NSBezierPath(ovalIn: CGRect(x: c.x - r + width / 2, y: c.y - r + width / 2,
                                                  width: 2 * r - width, height: 2 * r - width))
        outline.lineWidth = width
        outline.stroke()
    }

    /// A dot with a horizontal gradient through all hues, for the rainbow ink.
    /// Automatic colour: a white dot with a black "A".
    private static func autoDot() -> NSImage {
        NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let r: CGFloat = 13
            NSColor.white.setFill()
            NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)).fill()
            if let g = NSGraphicsContext.current?.cgContext {
                g.setFillColor(NSColor.black.cgColor)
                g.addPath(Toolbar.letterA(center: c, height: 12))
                g.fillPath()
            }
            Toolbar.strokeOutline(center: c, radius: r)
            return true
        }
    }

    private static func rainbowDot() -> NSImage {
        NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let r: CGFloat = 13
            let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple]
            for (i, color) in colors.enumerated() {
                let path = NSBezierPath()
                path.move(to: c)
                path.appendArc(withCenter: c, radius: r, startAngle: CGFloat(i) * 60 + 90, endAngle: CGFloat(i + 1) * 60 + 90)
                path.close()
                color.setFill()
                path.fill()
            }
            Toolbar.strokeOutline(center: c, radius: r)
            return true
        }
    }

    /// A thin vertical line with extra room on both sides (the stack's own spacing plus 6 pt).
    private static func divider() -> NSView {
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 13).isActive = true
        box.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor(white: 1, alpha: 0.18).cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(line)
        NSLayoutConstraint.activate([
            line.widthAnchor.constraint(equalToConstant: 1),
            line.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            line.topAnchor.constraint(equalTo: box.topAnchor),
            line.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        return box
    }

    /// The simple cursor: a solid dot in the colour it will draw with.
    /// In the toolbar it shows the real stroke size and opacity: the 64 pt image is drawn padded
    /// (75 %) in a 40 pt button, so sizes are scaled up by that much here.
    static func colorPointerIcon(_ color: CGColor, live: Bool = true) -> NSImage {
        let shown: CGFloat = 40.0 / 64.0 * 0.75
        // Real size, but never bigger than the button.
        let r = live ? min(30, CGFloat(Preferences.strokeSize) / 2 / shown) : 7
        let alpha = live ? CGFloat(Preferences.inkOpacity) / 100 : 1
        return NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let dot = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
            // It shows the chosen ink the way its button does: rainbow as the rainbow, automatic
            // as white with an "A" (just a black dot in the middle when it is small).
            let choice = live ? Preferences.inkChoice : .match
            NSGraphicsContext.current?.cgContext.setAlpha(alpha)
            switch choice {
            case .rainbow:
                let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple]
                for (i, color) in colors.enumerated() {
                    let wedge = NSBezierPath()
                    wedge.move(to: c)
                    wedge.appendArc(withCenter: c, radius: r, startAngle: CGFloat(i) * 60 + 90, endAngle: CGFloat(i + 1) * 60 + 90)
                    wedge.close()
                    color.setFill()
                    wedge.fill()
                }
            case .match where live:
                NSColor.white.setFill()
                NSBezierPath(ovalIn: dot).fill()
                // On screen the dot is r × shown points wide; below about 16 pt an "A" can't be read.
                if r * shown * 2 >= 16 {
                    if let g = NSGraphicsContext.current?.cgContext {
                        g.setFillColor(NSColor.black.cgColor)
                        g.addPath(Toolbar.letterA(center: c, height: r * 0.95))
                        g.fillPath()
                    }
                } else {
                    let m = max(1.5 / shown, r * 0.3)
                    NSColor.black.setFill()
                    NSBezierPath(ovalIn: CGRect(x: c.x - m, y: c.y - m, width: 2 * m, height: 2 * m)).fill()
                }
            default:
                (NSColor(cgColor: color) ?? .white).setFill()
                NSBezierPath(ovalIn: dot).fill()
            }
            NSGraphicsContext.current?.cgContext.setAlpha(1)
            // Same ring as the colour dots; this image is shown smaller (padded), so a bit wider.
            Toolbar.strokeOutline(center: c, radius: r, width: (40.0 / 64.0) / shown)
            return true
        }
    }

    /// Draws the image at 75% of its size, centred, so the selection frame has room around the hand.
    static func padded(_ image: NSImage?, scale: CGFloat = 0.75) -> NSImage? {
        guard let image = image else {
            return nil
        }
        return NSImage(size: image.size, flipped: false) { rect in
            let w = rect.width * scale
            let h = rect.height * scale
            image.draw(in: CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
            return true
        }
    }

    static func icon(for style: PointerStyle) -> NSImage? {
        if let name = style.assetName {
            return HandAsset.thumbnail(name)
        }
        if style == .stroke {
            return colorPointerIcon(Ink.hex(0xFFFFFF))
        }
        return NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let red = NSColor(cgColor: Ink.red) ?? .systemRed
            let glow = NSGradient(colors: [red.withAlphaComponent(0.55), red.withAlphaComponent(0)])
            glow?.draw(in: NSBezierPath(ovalIn: rect.insetBy(dx: 14, dy: 14)), relativeCenterPosition: .zero)
            red.setFill()
            NSBezierPath(ovalIn: CGRect(x: c.x - 7, y: c.y - 7, width: 14, height: 14)).fill()
            NSColor(srgbRed: 1, green: 0.86, blue: 0.82, alpha: 0.95).setFill()
            NSBezierPath(ovalIn: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)).fill()
            return true
        }
    }
}
