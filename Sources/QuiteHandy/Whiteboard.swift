import AppKit
import ScreenCaptureKit

/// Whiteboards to draw on. While the pointer is on, two sheets of paper peek out of the bottom
/// right corner (with a cog above them for Settings). Clicking the sheets opens a new board that
/// floats to the middle; dragging them pulls a sheet out up to the pointer, and releasing cuts it
/// there and lets it float to the middle.
///
/// Any number of boards can be open. A click brings a board to the front; lines and stamps go on
/// the board under the pointer, or on the screen when there is none. Each board has a grip at
/// the top middle to move it, chevron handles in its top left and bottom right corners to resize
/// it, and ghost buttons along its top: light/dark, copy, save as PNG on the Desktop, close.
final class Whiteboard {
    enum Hit {
        case peek, close, save, copy, theme, topLeft, bottomRight, board, none
        /// A board while it floats to the middle: grab it to place it yourself.
        case floating
        /// The grip at a board's top middle: drag to move the board.
        case grip
        /// The cog above the sheets in the corner: opens Settings.
        case settings
    }

    /// What undo and redo bring back for one board: whether it is open, where, and where its
    /// drawing sits (it moves with the board).
    struct State: Equatable {
        var isOpen: Bool
        var rect: CGRect
        var offset: CGPoint
    }

    /// Told when a board settled into a new state (opened, closed, cut, resized, moved).
    var onChange: ((Board, State, State) -> Void)?
    /// Told about every new step in any board's ink, for the shared history.
    var onInkRecord: ((Ink) -> Void)?
    /// A stamp on a board grew to full size and was put down on its own.
    var onStampPopped: (() -> Void)?

    private(set) var boards: [Board] = []
    private let window: NSWindow
    private let root = CALayer()
    private let peek = CALayer()
    /// A second sheet under the peeking one, fanned out towards the bottom left.
    private let peekBack = CALayer()
    /// Cog above the peeking sheets: the way to Settings, also with the menu bar icon hidden.
    /// A white cog on a round, 10 % black background, so it shows on light and dark screens alike.
    private let cog = CALayer()
    private var screenSize = CGSize(width: 1440, height: 900)
    private var peekLifted = false
    private var cogHovered = false
    /// True when the screen behind the cog is light: then it is a black cog on 10 % white,
    /// otherwise a white cog on 10 % black.
    private var cogOnLight = false
    private var lastCogSample = Date.distantPast
    /// The board being pulled out of the corner (it only appears once the pointer has moved).
    private var pulling: (board: Board, start: CGPoint, started: Bool)?
    /// The board being carried by its grip (or caught while floating).
    private var carried: Board?

    fileprivate static let floatDuration: CFTimeInterval = 0.7
    fileprivate static let barHeight: CGFloat = 56
    fileprivate static let buttonSize: CGFloat = 40
    fileprivate static let buttonGap: CGFloat = 6
    fileprivate static let handleInset: CGFloat = 26
    fileprivate static let minSize = CGSize(width: 480, height: 270)
    private static let peekSize = CGSize(width: 80, height: 80)

    init() {
        // Created at the screen's size, so showing it never stretches what is already drawn.
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        screenSize = screen.size
        window = NSWindow(contentRect: screen, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        // No zoom-in when shown: macOS would grow it from smaller, cutting off its edges.
        window.animationBehavior = .none
        // Above the screen ink, below the hand.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let view = NSView(frame: CGRect(origin: .zero, size: screen.size))
        view.wantsLayer = true
        view.layer = root
        window.contentView = view
        // No implicit animations on the root: a new screen size must not scale anything.
        root.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "contents": NSNull(), "sublayers": NSNull()]

        for sheet in [peekBack, peek] {
            sheet.backgroundColor = NSColor.white.cgColor
            sheet.cornerRadius = 3
            sheet.shadowColor = NSColor.black.cgColor
            sheet.shadowOpacity = 0.25
            sheet.shadowRadius = 8
            sheet.shadowOffset = CGSize(width: 0, height: -2)
            sheet.bounds = CGRect(origin: .zero, size: Whiteboard.peekSize)
            // Turn around the bottom right corner, so the lower sheet fans out to the bottom left.
            sheet.anchorPoint = CGPoint(x: 1, y: 0)
            root.addSublayer(sheet)
        }
        peekBack.backgroundColor = NSColor(white: 0.94, alpha: 1).cgColor
        peekBack.setAffineTransform(CGAffineTransform(rotationAngle: 0.14))

        cog.bounds = CGRect(x: 0, y: 0, width: Whiteboard.buttonSize, height: Whiteboard.buttonSize)
        cog.cornerRadius = Whiteboard.buttonSize / 2
        let cogIcon = CALayer()
        cogIcon.frame = cog.bounds.insetBy(dx: 10, dy: 10)
        cogIcon.contentsGravity = .resizeAspect
        cogIcon.contentsScale = 2
        cogIcon.contents = Whiteboard.lucideImage("cog", color: .white)
        cogIcon.shadowColor = NSColor.black.cgColor
        cogIcon.shadowOpacity = 0.25
        cogIcon.shadowRadius = 1
        cogIcon.shadowOffset = .zero
        cog.addSublayer(cogIcon)
        root.addSublayer(cog)
        layoutCorner()
    }

    // MARK: - Showing

    /// Shows the sheets in the corner and the open boards on the screen with `frame`.
    func show(on frame: CGRect) {
        if window.frame != frame {
            window.setFrame(frame, display: false)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = CGRect(origin: .zero, size: frame.size)
        CATransaction.commit()
        screenSize = frame.size
        layoutCorner()
        boards.forEach { $0.layout() }
        window.orderFrontRegardless()
        // The cog fades in once the sheets have slid in (0.1 s apart, 0.45 s each), already in the
        // colours for what is behind it.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cog.opacity = 0
        CATransaction.commit()
        let shown = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.lastCogSample = Date()
            self?.sampleBehindCog { [weak self] in
                let wait = max(0, 0.55 - Date().timeIntervalSince(shown))
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                    guard let self = self, self.window.isVisible else {
                        return
                    }
                    CATransaction.begin()
                    CATransaction.setAnimationDuration(0.4)
                    self.cog.opacity = 1
                    CATransaction.commit()
                }
            }
        }
    }

    /// Its window, so the overlay can hide it while it moves to another screen.
    var windows: [NSWindow] { [window] }

    func hide() {
        window.orderOut(nil)
    }

    /// Everything gone (the pointer was turned off with a right click or Esc).
    func reset() {
        boards.forEach { $0.container.removeFromSuperlayer() }
        boards = []
        pulling = nil
        carried = nil
    }

    var hasOpenBoard: Bool { boards.contains { $0.isOpen } }

    /// True while a board floats, so the overlay keeps updating at full speed.
    var isAnimating: Bool { boards.contains { $0.isFloating } }

    /// Call on every overlay tick: floats boards and shows hover effects.
    func update(mouse: CGPoint) {
        // Only look again when the pointer comes near the corner (a screen capture briefly
        // lights up macOS's recording indicator, so not all the time).
        let nearCorner = hypot(mouse.x - cog.position.x, mouse.y - cog.position.y) < 260
        if nearCorner && Date().timeIntervalSince(lastCogSample) > 3 {
            lastCogSample = Date()
            sampleBehindCog()
        }
        for b in boards where b.isFloating {
            b.stepFloat()
        }
        let top = board(at: mouse)
        for b in boards {
            b.setHover(b === top ? b.control(at: mouse) : nil)
        }
        let overCog = top == nil && cog.frame.contains(mouse)
        if overCog != cogHovered {
            cogHovered = overCog
            layoutCorner()
        }
        let near = top == nil && !overCog && peekHitRect.insetBy(dx: -40, dy: -40).contains(mouse)
        if near != peekLifted {
            peekLifted = near
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.2)
            // The top sheet grows a little towards the pointer instead of moving.
            let scale: CGFloat = near ? 1.125 : 1
            peek.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
            CATransaction.commit()
        }
    }

    private func layoutCorner() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The straight top sheet shows fully (80 × 80, 90 × 90 when the pointer is near) in the corner; the turned one fans out behind it.
        let corner = CGPoint(x: screenSize.width, y: 0)
        peek.position = corner
        peekBack.position = corner
        cog.position = CGPoint(x: screenSize.width - Whiteboard.peekSize.width / 2, y: Whiteboard.peekSize.height + 24 + Whiteboard.buttonSize / 2)
        cog.backgroundColor = NSColor(white: cogOnLight ? 1 : 0, alpha: cogHovered ? 0.2 : 0.1).cgColor
        cog.sublayers?.first?.contents = Whiteboard.lucideImage("cog", color: cogOnLight ? .black : .white)
        cog.sublayers?.first?.shadowOpacity = cogOnLight ? 0 : 0.25
        // The cog itself at 60 %, fully there on hover.
        cog.sublayers?.first?.opacity = cogHovered ? 1 : 0.6
        CATransaction.commit()
    }

    /// When the pointer is turned on: the sheets slide in from beyond the bottom right corner.
    func animateIn() {
        // One after the other, the same way: the top sheet first, then the one behind it.
        for (sheet, delay) in [(peek, 0.0), (peekBack, 0.1)] {
            let slide = CABasicAnimation(keyPath: "position")
            slide.fromValue = NSValue(point: CGPoint(x: sheet.position.x + 120, y: sheet.position.y - 120))
            slide.toValue = NSValue(point: sheet.position)
            slide.beginTime = CACurrentMediaTime() + delay
            slide.duration = 0.45
            slide.fillMode = .backwards
            slide.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.3, 1)
            sheet.add(slide, forKey: "slideIn")
        }
    }

    /// Hides the sheets and the cog in the corner (while a screenshot is taken).
    func setCornerHidden(_ hidden: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        peek.isHidden = hidden
        peekBack.isHidden = hidden
        cog.isHidden = hidden
        CATransaction.commit()
    }

    private var screenToast: CALayer?
    private var screenToastToken = 0

    /// A short message (white on a black pill, with a check when it went well) in the middle of
    /// the screen, where the toolbar can't cover it.
    func showScreenToast(_ message: String, success: Bool) {
        screenToast?.removeFromSuperlayer()
        screenToastToken += 1
        let token = screenToastToken
        let pill = CALayer()
        pill.backgroundColor = NSColor(white: 0, alpha: 0.85).cgColor
        let text = CATextLayer()
        text.string = message
        text.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        text.fontSize = 13
        text.foregroundColor = NSColor.white.cgColor
        text.contentsScale = 2
        let textWidth = ceil(text.preferredFrameSize().width)
        let left: CGFloat = success ? 14 : 16
        let checkWidth: CGFloat = success ? 18 : 0
        let width = left + checkWidth + textWidth + 16
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pill.bounds = CGRect(x: 0, y: 0, width: width, height: 32)
        pill.cornerRadius = 16
        pill.position = CGPoint(x: screenSize.width / 2, y: screenSize.height / 2)
        text.frame = CGRect(x: left + checkWidth, y: 7, width: textWidth, height: 18)
        pill.addSublayer(text)
        if success {
            let check = CAShapeLayer()
            let k: CGFloat = 14 / 24
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 20 * k, y: 18 * k))
            path.addLine(to: CGPoint(x: 9 * k, y: 7 * k))
            path.addLine(to: CGPoint(x: 4 * k, y: 12 * k))
            check.path = path
            check.strokeColor = NSColor.white.cgColor
            check.fillColor = nil
            check.lineWidth = 2
            check.lineCap = .round
            check.lineJoin = .round
            check.frame = CGRect(x: left, y: 9, width: 14, height: 14)
            pill.addSublayer(check)
        }
        pill.opacity = 0
        root.addSublayer(pill)
        CATransaction.commit()
        screenToast = pill
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        pill.opacity = 1
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self, weak pill] in
            guard self?.screenToastToken == token, let pill = pill else {
                return
            }
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.4)
            pill.opacity = 0
            CATransaction.commit()
        }
    }

    // MARK: - Contrast for the cog

    /// Looks at the screen behind the cog (leaving out our own windows) and picks the cog's colours.
    /// With Screen Recording allowed this is what is really on screen; without it, the desktop
    /// picture at that spot.
    /// `done` runs on the main queue once the colours are set (or could not be found).
    private func sampleBehindCog(done: (() -> Void)? = nil) {
        guard window.isVisible, let screen = window.screen else {
            done?()
            return
        }
        let r = cog.frame
        // Screen coordinates with the origin at the top left, as screen capture wants them.
        let topLeft = CGRect(x: r.minX, y: screenSize.height - r.maxY, width: r.width, height: r.height)
        if #available(macOS 14.0, *), CGPreflightScreenCaptureAccess(), let id = screen.displayID {
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, _ in
                guard let content = content, let display = content.displays.first(where: { $0.displayID == id }) else {
                    DispatchQueue.main.async { done?() }
                    return
                }
                let me = content.applications.filter { $0.processID == getpid() }
                let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
                let config = SCStreamConfiguration()
                config.sourceRect = topLeft
                config.width = 8
                config.height = 8
                config.showsCursor = false
                SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, _ in
                    let light = image.flatMap(Whiteboard.isLight)
                    DispatchQueue.main.async {
                        if let light = light {
                            self?.setCogOnLight(light)
                        }
                        done?()
                    }
                }
            }
            return
        }
        defer { done?() }
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return
        }
        // The desktop picture fills the screen: take the same spot in it.
        let sx = CGFloat(image.width) / screenSize.width
        let sy = CGFloat(image.height) / screenSize.height
        let crop = CGRect(x: topLeft.minX * sx, y: topLeft.minY * sy, width: topLeft.width * sx, height: topLeft.height * sy)
        if let part = image.cropping(to: crop.integral), let light = Whiteboard.isLight(part) {
            setCogOnLight(light)
        }
    }

    private func setCogOnLight(_ light: Bool) {
        guard light != cogOnLight else {
            return
        }
        cogOnLight = light
        layoutCorner()
    }

    /// Whether an image is light on average (relative luminance above one half).
    private static func isLight(_ image: CGImage) -> Bool? {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let l = 0.2126 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.0722 * Double(pixel[2])
        return l / 255 > 0.5
    }

    private var peekHitRect: CGRect {
        CGRect(x: screenSize.width - Whiteboard.peekSize.width, y: 0, width: Whiteboard.peekSize.width, height: Whiteboard.peekSize.height)
    }

    fileprivate func defaultRect(cascade: Int = 0) -> CGRect {
        var w = screenSize.width * 0.62
        var h = w * 9 / 16
        if h > screenSize.height * 0.7 {
            h = screenSize.height * 0.7
            w = h * 16 / 9
        }
        let shift = CGFloat(cascade % 6) * 28
        return CGRect(x: (screenSize.width - w) / 2 + shift, y: (screenSize.height - h) / 2 - shift, width: w, height: h).integral
    }

    // MARK: - Boards

    private func makeBoard() -> Board {
        let b = Board(owner: self)
        b.ink.onRecord = { [weak self] ink in self?.onInkRecord?(ink) }
        b.ink.onStampPopped = { [weak self] in self?.onStampPopped?() }
        boards.append(b)
        // Boards lie on top of the sheets in the corner, like paper on a stack.
        root.addSublayer(b.container)
        return b
    }

    /// The open board on top at `p`, if any.
    func board(at p: CGPoint) -> Board? {
        boards.last { $0.isOpen && $0.rect.contains(p) }
    }

    /// A click on a board puts it on top of the others.
    func bringToFront(_ b: Board) {
        guard let i = boards.firstIndex(where: { $0 === b }), i != boards.count - 1 else {
            return
        }
        boards.remove(at: i)
        boards.append(b)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.addSublayer(b.container)
        CATransaction.commit()
    }

    /// What a click at `p` (screen-local coordinates) lands on, and on which board.
    func hit(_ p: CGPoint) -> (Hit, Board?) {
        if let b = board(at: p) {
            return (b.hit(p), b)
        }
        if cog.frame.contains(p) {
            return (.settings, nil)
        }
        return peekHitRect.contains(p) ? (.peek, nil) : (.none, nil)
    }

    fileprivate func changed(_ b: Board, from: State, to: State) {
        onChange?(b, from, to)
    }

    /// Undo/redo: puts a board back as it was, at once.
    func restore(_ b: Board, _ state: State) {
        b.restore(state)
    }

    // MARK: - Pulling a sheet out of the corner

    /// Mouse down on the peeking sheets: a click opens a new board, a drag pulls out a sheet.
    func beginPull(at p: CGPoint) {
        pulling = (makeBoard(), p, false)
    }

    func pull(to p: CGPoint) {
        guard var pull = pulling else {
            return
        }
        if !pull.started {
            guard hypot(p.x - pull.start.x, p.y - pull.start.y) > 6 else {
                return
            }
            pull.started = true
            pulling = pull
        }
        // The sheet comes out of the bottom right corner up to the pointer.
        let left = min(max(0, p.x), screenSize.width - 60)
        let top = max(min(screenSize.height, p.y), 40)
        pull.board.showPulled(CGRect(x: left, y: 0, width: screenSize.width - left, height: top))
    }

    /// Releasing cuts the sheet at its size and lets it float to the middle; a click opens a new
    /// board that floats out of the corner.
    func endPull() {
        guard let pull = pulling else {
            return
        }
        pulling = nil
        let cascade = boards.filter { $0.isOpen }.count
        if pull.started {
            let r = pull.board.rect
            let w = min(max(r.width, Whiteboard.minSize.width), screenSize.width * 0.9)
            let h = min(max(r.height, Whiteboard.minSize.height), screenSize.height * 0.9)
            let target = CGRect(x: (screenSize.width - w) / 2, y: (screenSize.height - h) / 2, width: w, height: h)
                .offsetBy(dx: CGFloat(cascade % 6) * 28, dy: -CGFloat(cascade % 6) * 28).integral
            pull.board.float(to: target)
        } else {
            let start = CGRect(x: screenSize.width - Whiteboard.peekSize.width, y: 0,
                               width: Whiteboard.peekSize.width, height: Whiteboard.peekSize.height)
            pull.board.showPulled(start)
            pull.board.float(to: defaultRect(cascade: cascade))
        }
    }

    // MARK: - Moving and resizing

    func grab(_ b: Board, at p: CGPoint) {
        carried = b
        b.grab(at: p)
    }

    func carry(to p: CGPoint) {
        carried?.carry(to: p)
    }

    func drop() {
        carried?.drop()
        carried = nil
    }

    /// Mouse down on a resize handle: remembers where on the handle it was grabbed.
    func beginResize(_ b: Board, _ handle: Hit, at p: CGPoint) {
        b.beginResize(handle, at: p)
    }

    func drag(_ b: Board, _ handle: Hit, to p: CGPoint) {
        b.resize(handle, to: p, screen: screenSize)
    }

    func endResize(_ b: Board) {
        b.commit()
    }

    func press(_ b: Board, _ hit: Hit) {
        b.press(hit, scale: window.backingScaleFactor)
    }

    /// Lucide icons (lucide.dev, ISC licence), drawn from their 24 × 24 outlines: 2 pt strokes
    /// with round caps and joins.
    /// Drawn at the size it is shown (`points` at 2×, so it stays sharp) with `stroke` points wide lines.
    static func lucideImage(_ name: String, color: NSColor, points: CGFloat = 20, stroke: CGFloat = 1.75) -> CGImage? {
        let px = Int(points * 2)
        let lineWidth = stroke * 24 / points
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        // Lucide's y axis points down.
        ctx.translateBy(x: 0, y: CGFloat(px))
        ctx.scaleBy(x: CGFloat(px) / 24, y: -CGFloat(px) / 24)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let p = CGMutablePath()
        switch name {
        case "x":
            p.move(to: CGPoint(x: 18, y: 6)); p.addLine(to: CGPoint(x: 6, y: 18))
            p.move(to: CGPoint(x: 6, y: 6)); p.addLine(to: CGPoint(x: 18, y: 18))
        case "copy":
            p.addRoundedRect(in: CGRect(x: 8, y: 8, width: 14, height: 14), cornerWidth: 2, cornerHeight: 2)
            p.move(to: CGPoint(x: 4, y: 16))
            p.addArc(tangent1End: CGPoint(x: 2, y: 16), tangent2End: CGPoint(x: 2, y: 14), radius: 2)
            p.addLine(to: CGPoint(x: 2, y: 4))
            p.addArc(tangent1End: CGPoint(x: 2, y: 2), tangent2End: CGPoint(x: 4, y: 2), radius: 2)
            p.addLine(to: CGPoint(x: 14, y: 2))
            p.addArc(tangent1End: CGPoint(x: 16, y: 2), tangent2End: CGPoint(x: 16, y: 4), radius: 2)
        case "download":
            // square-arrow-down-enter
            p.move(to: CGPoint(x: 12, y: 3)); p.addLine(to: CGPoint(x: 12, y: 13))
            p.move(to: CGPoint(x: 16, y: 3)); p.addLine(to: CGPoint(x: 19, y: 3))
            p.addArc(tangent1End: CGPoint(x: 21, y: 3), tangent2End: CGPoint(x: 21, y: 5), radius: 2)
            p.addLine(to: CGPoint(x: 21, y: 19))
            p.addArc(tangent1End: CGPoint(x: 21, y: 21), tangent2End: CGPoint(x: 19, y: 21), radius: 2)
            p.addLine(to: CGPoint(x: 5, y: 21))
            p.addArc(tangent1End: CGPoint(x: 3, y: 21), tangent2End: CGPoint(x: 3, y: 19), radius: 2)
            p.addLine(to: CGPoint(x: 3, y: 5))
            p.addArc(tangent1End: CGPoint(x: 3, y: 3), tangent2End: CGPoint(x: 5, y: 3), radius: 2)
            p.addLine(to: CGPoint(x: 8, y: 3))
            p.move(to: CGPoint(x: 8, y: 9)); p.addLine(to: CGPoint(x: 12, y: 13)); p.addLine(to: CGPoint(x: 16, y: 9))
        case "cog":
            let segments: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
                (11, 10.27, 7, 3.34), (11, 13.73, 7, 20.66), (12, 22, 12, 20), (12, 2, 12, 4), (14, 12, 22, 12),
                (17, 20.66, 16, 18.93), (17, 3.34, 16, 5.07), (2, 12, 4, 12), (20.66, 17, 18.93, 16),
                (20.66, 7, 18.93, 8), (3.34, 17, 5.07, 16), (3.34, 7, 5.07, 8)]
            for l in segments {
                p.move(to: CGPoint(x: l.0, y: l.1)); p.addLine(to: CGPoint(x: l.2, y: l.3))
            }
            p.addEllipse(in: CGRect(x: 10, y: 10, width: 4, height: 4))
            p.addEllipse(in: CGRect(x: 4, y: 4, width: 16, height: 16))
        case "scissors":
            p.addEllipse(in: CGRect(x: 3, y: 3, width: 6, height: 6))
            p.addEllipse(in: CGRect(x: 3, y: 15, width: 6, height: 6))
            p.move(to: CGPoint(x: 8.12, y: 8.12)); p.addLine(to: CGPoint(x: 12, y: 12))
            p.move(to: CGPoint(x: 20, y: 4)); p.addLine(to: CGPoint(x: 8.12, y: 15.88))
            p.move(to: CGPoint(x: 14.8, y: 14.8)); p.addLine(to: CGPoint(x: 20, y: 20))
        case "sun":
            p.addEllipse(in: CGRect(x: 8, y: 8, width: 8, height: 8))
            let rays: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
                (12, 2, 12, 4), (12, 20, 12, 22), (4.93, 4.93, 6.34, 6.34), (17.66, 17.66, 19.07, 19.07),
                (2, 12, 4, 12), (20, 12, 22, 12), (6.34, 17.66, 4.93, 19.07), (19.07, 4.93, 17.66, 6.34)]
            for r in rays {
                p.move(to: CGPoint(x: r.0, y: r.1)); p.addLine(to: CGPoint(x: r.2, y: r.3))
            }
        case "moon-star":
            // The crescent: a small arc into the moon, then the big outer arc back.
            p.move(to: CGPoint(x: 12, y: 3))
            p.addArc(center: CGPoint(x: 16.5, y: 7.5), radius: 4.5 * 2.squareRoot(),
                     startAngle: -.pi * 3 / 4, endAngle: .pi / 4 - 2 * .pi, clockwise: true)
            p.addArc(center: CGPoint(x: 12, y: 12), radius: 9, startAngle: 0, endAngle: .pi * 3 / 2, clockwise: false)
            p.move(to: CGPoint(x: 20, y: 3)); p.addLine(to: CGPoint(x: 20, y: 7))
            p.move(to: CGPoint(x: 22, y: 5)); p.addLine(to: CGPoint(x: 18, y: 5))
        case "contrast":
            p.addEllipse(in: CGRect(x: 2, y: 2, width: 20, height: 20))
            ctx.addPath(p)
            ctx.strokePath()
            // The filled right half.
            let half = CGMutablePath()
            half.move(to: CGPoint(x: 12, y: 18))
            half.addArc(center: CGPoint(x: 12, y: 12), radius: 6, startAngle: .pi / 2, endAngle: -.pi / 2, clockwise: true)
            half.closeSubpath()
            ctx.setFillColor(color.cgColor)
            ctx.addPath(half)
            ctx.fillPath()
            return ctx.makeImage()
        default:
            break
        }
        ctx.addPath(p)
        ctx.strokePath()
        return ctx.makeImage()
    }


    // MARK: - Test

    /// For --whiteboard-test: renders an open board with a line (`--pulling` shows a sheet being
    /// pulled out, `--peek` only the corner) on a grey screen.
    static func renderTest(outPath: String, pulling: Bool) {
        let size = CGSize(width: 1440, height: 900)
        let wb = Whiteboard()
        wb.screenSize = size
        wb.layoutCorner()
        if CommandLine.arguments.contains("--peek") {
        } else if pulling {
            wb.beginPull(at: CGPoint(x: size.width - 20, y: 20))
            wb.pull(to: CGPoint(x: 820, y: 420))
        } else {
            let b = wb.makeBoard()
            b.showPulled(wb.defaultRect())
            b.restore(State(isOpen: true, rect: wb.defaultRect(), offset: wb.defaultRect().origin))
            let ink = b.ink
            ink.scale = 2
            ink.color = Ink.red
            ink.zebra = ProcessInfo.processInfo.environment["TH_ZEBRA"] != nil
            let o = b.offset
            ink.begin(at: CGPoint(x: 500 - o.x, y: 400 - o.y), width: 8)
            for i in 1...40 {
                let t = CGFloat(i) / 40
                ink.extend(to: CGPoint(x: 500 + 400 * t - o.x, y: 400 + 120 * sin(t * 6) - o.y))
            }
            ink.end()
        }
        guard let ctx = CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return
        }
        ctx.scaleBy(x: 2, y: 2)
        ctx.setFillColor(CGColor(gray: 0.55, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        wb.root.frame = CGRect(origin: .zero, size: size)
        wb.root.render(in: ctx)
        if let image = ctx.makeImage(),
           let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: outPath))
            print("rendered \(outPath)")
        }
    }

    // MARK: - One board

    /// One whiteboard: its paper, its ink, its controls.
    final class Board {
        let ink = Ink()
        /// Holds everything of this board; its place among the root's sublayers is its z-order.
        let container = CALayer()
        private unowned let owner: Whiteboard
        private let shadowLayer = CALayer()
        private let clip = CALayer()
        private let cutLabel = CATextLayer()
        /// Lucide scissors in front of the "cut" hint, at the sheet's bottom left.
        private let cutIcon = CALayer()
        /// A second pair of scissors at the top right, pointing down, and dashed cut lines: one
        /// from the hint to the right edge, one from the top scissors down the right edge, both to the edge.
        private let cutIconTop = CALayer()
        private let cutLines = CAShapeLayer()
        /// A short message at the bottom middle of the board ("Saved to Desktop", …): white
        /// text on a black pill, fading out after a moment.
        private let toast = CALayer()
        private let toastText = CATextLayer()
        /// Lucide check in front of a success message.
        private let toastCheck = CAShapeLayer()
        private var toastToken = 0
        private let grip = CAShapeLayer()
        private let gripHover = CALayer()
        private let topLeftHandle = CAShapeLayer()
        private let bottomRightHandle = CAShapeLayer()
        private var buttons: [(hit: Hit, layer: CALayer, symbol: String)] = []
        private var hovered: Hit?

        private(set) var isOpen = false
        private(set) var rect = CGRect.zero
        /// Where the ink's origin sits on the screen: the drawing moves with the board.
        private(set) var offset = CGPoint.zero
        /// nil follows the system; otherwise the board was switched by hand.
        private var darkOverride: Bool?
        private var floating: (from: CGRect, to: CGRect, start: CFTimeInterval)?
        private var pulled = false
        private var carryOffset: CGPoint?
        private var settled = State(isOpen: false, rect: .zero, offset: .zero)

        fileprivate init(owner: Whiteboard) {
            self.owner = owner
            ink.alwaysKeep = true
            ink.scale = owner.window.backingScaleFactor
            container.actions = ["sublayers": NSNull(), "position": NSNull(), "bounds": NSNull()]
            shadowLayer.shadowColor = NSColor.black.cgColor
            shadowLayer.shadowOpacity = 0.35
            shadowLayer.shadowRadius = 24
            shadowLayer.shadowOffset = CGSize(width: 0, height: -6)
            shadowLayer.cornerRadius = 6
            container.addSublayer(shadowLayer)
            clip.cornerRadius = 6
            clip.masksToBounds = true
            clip.addSublayer(ink.layer)
            shadowLayer.addSublayer(clip)
            cutLabel.string = "Release to cut here"
            cutLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
            cutLabel.fontSize = 13
            cutLabel.foregroundColor = NSColor(white: 0.55, alpha: 1).cgColor
            cutLabel.alignmentMode = .left
            cutLabel.contentsScale = 2
            cutLabel.isHidden = true
            clip.addSublayer(cutLabel)
            cutIcon.contents = Whiteboard.lucideImage("scissors", color: NSColor(white: 0.55, alpha: 1), points: 16)
            cutIcon.contentsGravity = .resizeAspect
            cutIcon.contentsScale = 2
            cutIcon.isHidden = true
            clip.addSublayer(cutIcon)
            cutIconTop.contents = cutIcon.contents
            cutIconTop.contentsGravity = .resizeAspect
            cutIconTop.bounds = CGRect(x: 0, y: 0, width: 16, height: 16)
            cutIconTop.setAffineTransform(CGAffineTransform(rotationAngle: -.pi / 2))
            cutIconTop.isHidden = true
            clip.addSublayer(cutIconTop)
            cutLines.strokeColor = NSColor(white: 0.55, alpha: 0.8).cgColor
            cutLines.fillColor = nil
            cutLines.lineWidth = 1
            cutLines.lineDashPattern = [6, 5]
            cutLines.isHidden = true
            clip.addSublayer(cutLines)

            // Resize handles: thin Lucide chevrons (chevron-right, turned to point into the
            // corner) on a ghost button that lights up on hover, like the toolbar.
            let box = Whiteboard.buttonSize
            // The chevron sits towards its corner inside the hover square.
            let shift: CGFloat = 3
            for (handle, angle, dx, dy) in [(topLeftHandle, CGFloat.pi * 3 / 4, -shift, shift),
                                            (bottomRightHandle, -CGFloat.pi / 4, shift, -shift)] {
                let chevron = CGMutablePath()
                // Twice Lucide's size, so the corner is easy to see; the stroke stays thin.
                let k: CGFloat = 40 / 24
                chevron.move(to: CGPoint(x: 9 * k, y: 6 * k))
                chevron.addLine(to: CGPoint(x: 15 * k, y: 12 * k))
                chevron.addLine(to: CGPoint(x: 9 * k, y: 18 * k))
                var t = CGAffineTransform(translationX: box / 2 + dx, y: box / 2 + dy)
                    .rotated(by: angle)
                    .translatedBy(x: -12 * k, y: -12 * k)
                handle.bounds = CGRect(x: 0, y: 0, width: box, height: box)
                handle.path = chevron.copy(using: &t)
                handle.fillColor = nil
                handle.lineWidth = 1.75
                handle.lineCap = .round
                handle.lineJoin = .round
                handle.cornerRadius = 10
                container.addSublayer(handle)
            }
            gripHover.cornerRadius = 10
            container.addSublayer(gripHover)
            // Grip at the top middle to move the board: 12 × 2 dots like the toolbar's grip.
            let dots = CGMutablePath()
            for col in 0..<12 {
                for row in 0..<2 {
                    dots.addEllipse(in: CGRect(x: CGFloat(col) * 4.5 + 1, y: CGFloat(row) * 4.5 + 1, width: 2.5, height: 2.5))
                }
            }
            grip.path = dots
            grip.bounds = CGRect(x: 0, y: 0, width: 12 * 4.5, height: 2 * 4.5)
            container.addSublayer(grip)
            // Right to left along the top of the board: close at the far right.
            let symbols: [(Hit, String)] = [(.close, "x"), (.save, "download"), (.copy, "copy"), (.theme, "contrast")]
            for (hit, symbol) in symbols {
                let b = CALayer()
                b.bounds = CGRect(x: 0, y: 0, width: box, height: box)
                b.cornerRadius = 10
                let icon = CALayer()
                icon.frame = b.bounds.insetBy(dx: 10, dy: 10)
                icon.contentsGravity = .resizeAspect
                icon.contentsScale = 2
                b.addSublayer(icon)
                container.addSublayer(b)
                buttons.append((hit, b, symbol))
            }
            toast.backgroundColor = NSColor(white: 0, alpha: 0.85).cgColor
            toast.opacity = 0
            toastText.font = NSFont.systemFont(ofSize: 13, weight: .medium)
            toastText.fontSize = 13
            toastText.foregroundColor = NSColor.white.cgColor
            toastText.alignmentMode = .center
            toastText.contentsScale = 2
            toast.addSublayer(toastText)
            let check = CGMutablePath()
            // Lucide "check" (y up): M20 6 9 17l-5-5, at 14 pt.
            let k: CGFloat = 14 / 24
            check.move(to: CGPoint(x: 20 * k, y: (24 - 6) * k))
            check.addLine(to: CGPoint(x: 9 * k, y: (24 - 17) * k))
            check.addLine(to: CGPoint(x: 4 * k, y: (24 - 12) * k))
            toastCheck.path = check
            toastCheck.strokeColor = NSColor.white.cgColor
            toastCheck.fillColor = nil
            toastCheck.lineWidth = 2
            toastCheck.lineCap = .round
            toastCheck.lineJoin = .round
            toast.addSublayer(toastCheck)
            container.addSublayer(toast)
            container.isHidden = true
        }

        /// Shows `message` at the bottom middle of the board for a moment, with a check in front
        /// when it went well.
        fileprivate func showToast(_ message: String, success: Bool = true) {
            toastToken += 1
            let token = toastToken
            toastText.string = message
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let textWidth = ceil(toastText.preferredFrameSize().width)
            // With a check: 14 pt to the check, 4 pt from check to text; without: 16 pt.
            let left: CGFloat = success ? 14 : 16
            let checkWidth: CGFloat = success ? 14 + 4 : 0
            let width = left + checkWidth + textWidth + 16
            toast.bounds = CGRect(x: 0, y: 0, width: width, height: 32)
            toast.cornerRadius = 16
            toastCheck.isHidden = !success
            toastCheck.frame = CGRect(x: left, y: 9, width: 14, height: 14)
            toastText.frame = CGRect(x: left + checkWidth, y: 7, width: textWidth, height: 18)
            toast.position = CGPoint(x: rect.midX, y: rect.minY + 20 + 16)
            CATransaction.commit()
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.15)
            toast.opacity = 1
            CATransaction.commit()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
                guard let self = self, self.toastToken == token else {
                    return
                }
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.4)
                self.toast.opacity = 0
                CATransaction.commit()
            }
        }

        var isFloating: Bool { floating != nil }

        private var isDark: Bool {
            if let d = darkOverride {
                return d
            }
            return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }

        private var background: CGColor {
            isDark ? Ink.hex(0x1E1E1E) : Ink.hex(0xFFFFFF)
        }

        /// The new state goes into the history, if it changed.
        fileprivate func commit(_ state: State? = nil) {
            let now = state ?? State(isOpen: isOpen, rect: rect, offset: offset)
            guard now != settled else {
                return
            }
            let before = settled
            settled = now
            owner.changed(self, from: before, to: now)
        }

        fileprivate func restore(_ state: State) {
            floating = nil
            pulled = false
            carryOffset = nil
            isOpen = state.isOpen
            rect = state.rect
            offset = state.offset
            settled = state
            layout()
        }

        /// While being pulled out: plain paper with the "cut" hint, at `r`.
        fileprivate func showPulled(_ r: CGRect) {
            if !isOpen {
                offset = r.origin
            }
            isOpen = true
            pulled = true
            move(to: r)
        }

        /// Floats (slow ease-out) to `target`; the state there goes into the history now.
        fileprivate func float(to target: CGRect) {
            pulled = false
            floating = (rect, target, CACurrentMediaTime())
            commit(State(isOpen: true, rect: target, offset: CGPoint(x: offset.x + target.minX - rect.minX,
                                                                      y: offset.y + target.minY - rect.minY)))
            layout()
        }

        fileprivate func stepFloat() {
            guard let f = floating else {
                return
            }
            let t = min(1, (CACurrentMediaTime() - f.start) / Whiteboard.floatDuration)
            // A slow ease-out, like a sheet of paper settling.
            let e = CGFloat(1 - pow(1 - t, 4))
            var r = CGRect(x: f.from.minX + (f.to.minX - f.from.minX) * e, y: f.from.minY + (f.to.minY - f.from.minY) * e,
                           width: f.from.width + (f.to.width - f.from.width) * e,
                           height: f.from.height + (f.to.height - f.from.height) * e)
            if t >= 1 {
                r = f.to
                floating = nil
            }
            move(to: r)
        }

        /// Sets a new frame; the drawing moves along with the board's corner.
        private func move(to r: CGRect) {
            offset = CGPoint(x: offset.x + r.minX - rect.minX, y: offset.y + r.minY - rect.minY)
            rect = r
            layout()
        }

        fileprivate func grab(at p: CGPoint) {
            floating = nil
            carryOffset = CGPoint(x: p.x - rect.minX, y: p.y - rect.minY)
            layout()
        }

        fileprivate func carry(to p: CGPoint) {
            guard let c = carryOffset else {
                return
            }
            move(to: CGRect(origin: CGPoint(x: p.x - c.x, y: p.y - c.y), size: rect.size))
        }

        fileprivate func drop() {
            carryOffset = nil
            commit()
            layout()
        }

        /// How far from the handle's centre it was grabbed, so it doesn't jump to the pointer.
        private var resizeGrab = CGPoint.zero

        fileprivate func beginResize(_ handle: Hit, at p: CGPoint) {
            let centre = handle == .topLeft ? topLeftHandle.position : bottomRightHandle.position
            resizeGrab = CGPoint(x: p.x - centre.x, y: p.y - centre.y)
        }

        /// Moves the edges that belong to `handle` to `p`; the drawing stays where it is.
        fileprivate func resize(_ handle: Hit, to pointer: CGPoint, screen: CGSize) {
            let p = CGPoint(x: pointer.x - resizeGrab.x, y: pointer.y - resizeGrab.y)
            var r = rect
            let minW = Whiteboard.minSize.width
            let minH = Whiteboard.minSize.height
            // The handle sits inside the corner: the edges follow it at that distance.
            let hi = Whiteboard.handleInset
            switch handle {
            case .topLeft:
                let left = min(max(0, p.x - hi), r.maxX - minW)
                let top = max(min(screen.height, p.y + hi), r.minY + minH)
                r = CGRect(x: left, y: r.minY, width: r.maxX - left, height: top - r.minY)
            case .bottomRight:
                let right = max(min(screen.width, p.x + hi), r.minX + minW)
                let bottom = min(max(0, p.y - hi), r.maxY - minH)
                r = CGRect(x: r.minX, y: bottom, width: right - r.minX, height: r.maxY - bottom)
            default:
                return
            }
            rect = r
            layout()
        }

        fileprivate func press(_ hit: Hit, scale: CGFloat) {
            switch hit {
            case .close:
                // A quick close: a little smaller around its centre while it fades out.
                let c = CGPoint(x: rect.midX, y: rect.midY)
                var small = CATransform3DMakeTranslation(c.x, c.y, 0)
                small = CATransform3DScale(small, 0.92, 0.92, 1)
                small = CATransform3DTranslate(small, -c.x, -c.y, 0)
                let shrink = CABasicAnimation(keyPath: "sublayerTransform")
                shrink.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
                shrink.toValue = NSValue(caTransform3D: small)
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 1
                fade.toValue = 0
                let group = CAAnimationGroup()
                group.animations = [shrink, fade]
                group.duration = 0.16
                group.timingFunction = CAMediaTimingFunction(name: .easeIn)
                group.fillMode = .forwards
                group.isRemovedOnCompletion = false
                CATransaction.begin()
                CATransaction.setCompletionBlock { [weak self] in
                    guard let self = self else {
                        return
                    }
                    self.isOpen = false
                    self.commit()
                    self.layout()
                    self.container.removeAnimation(forKey: "close")
                }
                container.add(group, forKey: "close")
                CATransaction.commit()
            case .theme:
                darkOverride = !isDark
                layout()
            case .save:
                saveToDesktop(scale: scale)
            case .copy:
                copyToClipboard(scale: scale)
            default:
                break
            }
            if let b = buttons.first(where: { $0.hit == hit })?.layer {
                let pop = CAKeyframeAnimation(keyPath: "transform.scale")
                pop.values = [1, 0.85, 1]
                pop.duration = 0.2
                b.add(pop, forKey: "pop")
            }
        }

        /// Plain paper while pulled out or floating: controls only come once it has landed.
        private var showsControls: Bool { isOpen && !pulled && floating == nil }

        /// The control under `p`, for hover effects.
        fileprivate func control(at p: CGPoint) -> Hit? {
            guard showsControls else {
                return nil
            }
            if let b = buttons.first(where: { $0.layer.frame.contains(p) }) {
                return b.hit
            }
            if topLeftHandle.frame.contains(p) {
                return .topLeft
            }
            if bottomRightHandle.frame.contains(p) {
                return .bottomRight
            }
            return gripHover.frame.contains(p) ? .grip : nil
        }

        fileprivate func setHover(_ h: Hit?) {
            if h != hovered {
                hovered = h
                layout()
            }
        }

        fileprivate func hit(_ p: CGPoint) -> Hit {
            if floating != nil {
                return .floating
            }
            return control(at: p) ?? .board
        }

        fileprivate func layout() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            container.isHidden = !isOpen
            shadowLayer.frame = rect
            shadowLayer.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: rect.size), cornerWidth: 6, cornerHeight: 6, transform: nil)
            clip.frame = CGRect(origin: .zero, size: rect.size)
            clip.backgroundColor = background
            // The ink's own coordinates start at `offset` on the screen.
            ink.layer.frame = CGRect(x: offset.x - rect.minX, y: offset.y - rect.minY, width: 0, height: 0)
            toast.position = CGPoint(x: rect.midX, y: rect.minY + 20 + 16)
            cutLabel.isHidden = !pulled
            cutIcon.isHidden = !pulled
            cutIconTop.isHidden = !pulled
            cutLines.isHidden = !pulled
            cutIcon.frame = CGRect(x: 14, y: 15, width: 16, height: 16)
            let labelWidth = ceil(cutLabel.preferredFrameSize().width)
            cutLabel.frame = CGRect(x: 36, y: 13, width: labelWidth, height: 18)
            cutIconTop.position = CGPoint(x: rect.width - 22, y: rect.height - 22)
            let lines = CGMutablePath()
            let midY: CGFloat = 22
            // Both lines run all the way to the sheet's right and bottom edges (they may cross).
            if rect.width > 36 + labelWidth + 10 {
                lines.move(to: CGPoint(x: 36 + labelWidth + 10, y: midY))
                lines.addLine(to: CGPoint(x: rect.width, y: midY))
            }
            if rect.height - 36 > 0 {
                lines.move(to: CGPoint(x: rect.width - 22, y: rect.height - 36))
                lines.addLine(to: CGPoint(x: rect.width - 22, y: 0))
            }
            cutLines.frame = CGRect(origin: .zero, size: rect.size)
            cutLines.path = lines
            let controls = !showsControls
            let iconColor: NSColor = isDark ? NSColor(white: 1, alpha: 0.85) : NSColor(white: 0, alpha: 0.7)
            let hoverColor = isDark ? NSColor(white: 1, alpha: 0.1).cgColor : NSColor(white: 0, alpha: 0.07).cgColor
            let hi = Whiteboard.handleInset
            topLeftHandle.position = CGPoint(x: rect.minX + hi, y: rect.maxY - hi)
            bottomRightHandle.position = CGPoint(x: rect.maxX - hi, y: rect.minY + hi)
            // Icons sit back at 60 % and come up fully under the pointer.
            func faded(_ hit: Hit) -> CGFloat { hovered == hit ? 1 : 0.6 }
            for (handle, hit) in [(topLeftHandle, Hit.topLeft), (bottomRightHandle, Hit.bottomRight)] {
                handle.isHidden = controls
                handle.strokeColor = iconColor.withAlphaComponent(iconColor.alphaComponent * faded(hit)).cgColor
                handle.backgroundColor = hovered == hit ? hoverColor : NSColor.clear.cgColor
            }
            let barY = rect.maxY - Whiteboard.barHeight / 2
            grip.isHidden = controls
            grip.position = CGPoint(x: rect.midX, y: barY)
            grip.fillColor = iconColor.withAlphaComponent(iconColor.alphaComponent * faded(.grip)).cgColor
            gripHover.isHidden = controls
            gripHover.frame = CGRect(x: rect.midX - 44, y: barY - Whiteboard.buttonSize / 2, width: 88, height: Whiteboard.buttonSize)
            gripHover.backgroundColor = hovered == .grip ? hoverColor : NSColor.clear.cgColor
            let inset = (Whiteboard.barHeight - Whiteboard.buttonSize) / 2
            for (i, b) in buttons.enumerated() {
                b.layer.isHidden = controls
                b.layer.position = CGPoint(x: rect.maxX - inset - Whiteboard.buttonSize / 2
                                              - CGFloat(i) * (Whiteboard.buttonSize + Whiteboard.buttonGap), y: barY)
                b.layer.backgroundColor = b.hit == hovered ? hoverColor : NSColor.clear.cgColor
                // Light/dark shows where a click takes you: the moon on a light board, the sun on a dark one.
                let symbol = b.hit == .theme ? (isDark ? "sun" : "moon-star") : b.symbol
                b.layer.sublayers?.first?.contents = Whiteboard.lucideImage(symbol, color: iconColor)
                b.layer.sublayers?.first?.opacity = Float(faded(b.hit))
            }
            CATransaction.commit()
        }

        /// The board as PNG data.
        private func png(scale: CGFloat) -> Data? {
            let w = Int(rect.width * scale)
            let h = Int(rect.height * scale)
            guard w > 0, h > 0,
                  let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return nil
            }
            ctx.scaleBy(x: scale, y: scale)
            ctx.setFillColor(background)
            ctx.fill(CGRect(origin: .zero, size: rect.size))
            ctx.translateBy(x: offset.x - rect.minX, y: offset.y - rect.minY)
            ink.layer.render(in: ctx)
            guard let image = ctx.makeImage() else {
                return nil
            }
            return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        }

        private func saveToDesktop(scale: CGFloat) {
            guard let data = png(scale: scale) else {
                return
            }
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
            let url = desktop.appendingPathComponent("Quite Handy \(f.string(from: Date())).png")
            do {
                try data.write(to: url)
                Log.write("whiteboard: saved \(url.lastPathComponent)")
                showToast("Whiteboard saved to desktop")
            } catch {
                Log.write("whiteboard: could not save: \(error.localizedDescription)")
                showToast("Could not save the whiteboard", success: false)
            }
        }

        private func copyToClipboard(scale: CGFloat) {
            guard let data = png(scale: scale) else {
                return
            }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setData(data, forType: .png)
            Log.write("whiteboard: copied")
            showToast("Whiteboard copied to clipboard")
        }
    }
}
