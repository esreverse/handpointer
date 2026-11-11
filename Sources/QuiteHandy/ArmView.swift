import AppKit

final class ArmView: NSView {
    private let group = CALayer()
    /// Holds rod and hand inside `group`; it scales from the grip along the stick when the
    /// pointer turns on, so the hand grows out along the way it points.
    private let grow = CALayer()
    private let rodLayer = CALayer()
    private let handLayer = CALayer()
    /// The stroke pointer: a dot as big, as opaque and in the colour of the line you would draw.
    private let brushLayer = CAShapeLayer()

    private(set) var style: PointerStyle = .lavender
    private var asset: HandAsset?

    private var handLenFrac: CGFloat = Preferences.pointerSize
    private let minRodFrac: CGFloat = 0.05
    private let gripLeanFrac: CGFloat = 0.30
    private let gripDepthFrac: CGFloat = 0.12
    private let gripFollow: CGFloat = 0.08
    private let liftFrac: CGFloat = 0.06

    /// Ink on the screen, and ink on the whiteboard; `ink` is the one drawing goes to right now.
    let screenInk = Ink()
    /// The ink of the whiteboard being drawn on, if any; otherwise drawing goes on the screen.
    var targetInk: Ink? {
        didSet {
            targetInk?.color = screenInk.color
            targetInk?.zebra = screenInk.zebra
            targetInk?.scale = screenInk.scale
        }
    }
    var ink: Ink { targetInk ?? screenInk }
    var held = false
    var inkWidth: CGFloat { CGFloat(Preferences.strokeSize) }

    private var pressAmount: CGFloat = 0
    private var gripX: CGFloat?
    private var lastPose: [CGFloat] = []
    private var gripTarget: CGFloat?
    private var displayImageHeight = 0

    var isSettling: Bool {
        if pressAmount > 0.002 {
            return true
        }
        guard let gx = gripX, let target = gripTarget else {
            return false
        }
        return abs(target - gx) > 0.5
    }

    /// Hides the hand while the zoom loupe is open.
    var hiddenForZoom = false {
        didSet {
            if hiddenForZoom != oldValue {
                let hidden = pointerHidden
                pointerHidden = hidden
            }
        }
    }

    var pointerHidden = false {
        didSet {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let dot = style == .stroke
            group.isHidden = pointerHidden || hiddenForZoom || dot
            brushLayer.isHidden = pointerHidden || hiddenForZoom || !dot
            CATransaction.commit()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let root = CALayer()
        root.masksToBounds = false
        layer = root
        wantsLayer = true
        root.addSublayer(screenInk.layer)
        root.addSublayer(group)

        root.addSublayer(brushLayer)
        brushLayer.strokeColor = nil

        group.masksToBounds = false
        group.addSublayer(grow)
        grow.anchorPoint = CGPoint(x: 0.5, y: 0)
        grow.addSublayer(rodLayer)
        grow.addSublayer(handLayer)
        for sub in [rodLayer, handLayer] {
            sub.contentsGravity = .resize
            sub.contentsScale = 2
            sub.anchorPoint = CGPoint(x: 0.5, y: 0)
            sub.shadowColor = NSColor.black.cgColor
            sub.shadowOpacity = 0.38
        }

        setStyle(PointerStyle.saved)
        NotificationCenter.default.addObserver(forName: Preferences.changed, object: nil, queue: .main) { [weak self] _ in
            self?.handLenFrac = Preferences.pointerSize
        }
    }

    /// A filled circle in the ink colour that keeps growing from the tap point until it has
    /// faded out completely.
    func ripple(at point: CGPoint) {
        let radius: CGFloat = 40
        let circle = CAShapeLayer()
        circle.path = CGPath(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2), transform: nil)
        circle.fillColor = ink.tapColor
        circle.strokeColor = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        circle.position = point
        circle.opacity = 0
        layer?.insertSublayer(circle, below: group)
        CATransaction.commit()

        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.35
        grow.toValue = 3
        grow.duration = 0.8
        grow.timingFunction = CAMediaTimingFunction(controlPoints: 0.15, 0.55, 0.4, 1)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.8
        // Ease-out cubic: the alpha drops quickly at first, then trails off.
        fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.33, 1, 0.68, 1)
        let anim = CAAnimationGroup()
        anim.animations = [grow, fade]
        anim.duration = 0.8
        anim.fillMode = .both
        anim.isRemovedOnCompletion = false
        circle.add(anim, forKey: "ripple")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) { [weak circle] in
            circle?.removeFromSuperlayer()
        }
    }

    /// Puts the zoom loupe above the ink and below the hand.
    func addLoupe(_ loupe: CALayer) {
        layer?.insertSublayer(loupe, below: group)
    }

    func updateInkColor() {
        screenInk.color = Preferences.inkChoice.resolved(for: style)
        // The glove draws black and white in turns, so its lines show on any background.
        screenInk.zebra = Preferences.inkChoice == .match && style == .glove
        targetInk?.color = screenInk.color
        targetInk?.zebra = screenInk.zebra
    }

    func setStyle(_ newStyle: PointerStyle) {
        style = newStyle
        asset = newStyle.assetName.flatMap(HandAsset.load)
        if newStyle.assetName != nil && asset == nil {
            style = .stroke
        }
        updateInkColor()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let a = asset, style.assetName != nil {
            group.anchorPoint = CGPoint(x: a.rodX, y: 0)
            displayImageHeight = 0
            updateDisplayImage(a)
            rodLayer.contentsRect = CGRect(x: 0, y: 1 - a.rodEnd, width: 1, height: a.rodEnd - a.wrist)
            handLayer.contentsRect = CGRect(x: 0, y: 1 - a.wrist, width: 1, height: a.wrist - a.handTop)
        }
        CATransaction.commit()
        let hidden = pointerHidden
        pointerHidden = hidden
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not used")
    }

    func press() {
        pressAmount = 1
    }

    private var lastCursor = CGPoint.zero

    /// After a colour shortcut: a small tap circle at the fingertip in the new colour, so you see
    /// which colour you now draw with.
    /// The colour-change circle, drawn at 2× for `radius` points.
    private static func inkFlashImage(radius: CGFloat, colour: CGColor) -> CGImage? {
        let px = Int(radius * 4)
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.scaleBy(x: 2, y: 2)
        ctx.setAlpha(CGFloat(Preferences.inkOpacity) / 100)
        let c = CGPoint(x: radius, y: radius)
        let disc = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
        switch Preferences.inkChoice {
        case .rainbow:
            let colours: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple]
            for (i, colour) in colours.enumerated() {
                let wedge = CGMutablePath()
                wedge.move(to: c)
                wedge.addArc(center: c, radius: radius, startAngle: (CGFloat(i) * 60 + 90) * .pi / 180,
                             endAngle: (CGFloat(i + 1) * 60 + 90) * .pi / 180, clockwise: false)
                wedge.closeSubpath()
                ctx.setFillColor(colour.cgColor)
                ctx.addPath(wedge)
                ctx.fillPath()
            }
        case .match:
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: disc)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.addPath(Toolbar.letterA(center: c, height: radius * 0.8))
            ctx.fillPath()
        default:
            ctx.setFillColor(colour)
            ctx.fillEllipse(in: disc)
        }
        return ctx.makeImage()
    }

    func flashInk() {
        updateInkColor()
        let radius: CGFloat = 36
        // Looks like the chosen ink's button: the rainbow as a rainbow, automatic as white with
        // an "A", any other colour as a plain dot.
        let circle = CALayer()
        circle.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
        circle.contents = ArmView.inkFlashImage(radius: radius, colour: ink.tapColor)
        circle.contentsScale = 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        circle.position = lastCursor
        circle.opacity = 0
        layer?.insertSublayer(circle, below: group)
        CATransaction.commit()
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.4
        grow.toValue = 1.8
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.33, 1, 0.68, 1)
        let anim = CAAnimationGroup()
        anim.animations = [grow, fade]
        anim.duration = 0.6
        anim.fillMode = .both
        anim.isRemovedOnCompletion = false
        circle.add(anim, forKey: "tap")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak circle] in
            circle?.removeFromSuperlayer()
        }
    }

    /// When the pointer is turned on: the hand on its stick grows out from the grip along the
    /// way it points (ease-out); the simple cursor's dot grows in where it is.
    func animateIn() {
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.4
        scale.toValue = 1
        scale.duration = 0.35
        scale.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.3, 1)
        grow.add(scale, forKey: "appear")
        brushLayer.add(scale, forKey: "appear")
    }

    func aim(cursor: CGPoint) {
        lastCursor = cursor
        let screenH = bounds.height
        let targetX = min(max(cursor.x + gripLeanFrac * bounds.width, bounds.width * 0.15), bounds.width * 1.05)
        let gx = gripX.map { $0 + (targetX - $0) * gripFollow } ?? targetX
        gripX = gx
        gripTarget = targetX
        let grip = CGPoint(x: gx, y: -gripDepthFrac * screenH)

        if !held {
            pressAmount += (0 - pressAmount) * 0.18
        }

        if style == .stroke {
            aimStroke(cursor: cursor)
            return
        }
        guard let a = asset else {
            return
        }
        updateDisplayImage(a)

        let dx = cursor.x - grip.x
        let dy = cursor.y - grip.y
        let reach = hypot(dx, dy)
        let aimAngle = atan2(dy, dx)

        let handPts = handLenFrac * screenH * (1 - 0.06 * pressAmount)
        let s = handPts / (a.wrist - a.handTop)
        let widthPts = s * a.aspect
        let handTipPts = (a.wrist - a.tip) * s
        let tipOffX = (a.tipX - a.rodX) * widthPts

        let along = sqrt(max(0, reach * reach - tipOffX * tipOffX))
        var rodLen = along - handTipPts
        rodLen = max(minRodFrac * screenH, rodLen)
        let tipAngle = atan2(rodLen + handTipPts, tipOffX)
        let rotation = aimAngle - tipAngle

        let lift = currentLift(screenH)
        let sx = lift * 0.6
        let sy = -lift
        let shadowOffset = CGSize(
            width: sx * cos(-rotation) - sy * sin(-rotation),
            height: sx * sin(-rotation) + sy * cos(-rotation)
        )

        let pose = [rotation, rodLen, handPts, widthPts, grip.x, lift, pressAmount, a.aspect]
            .map { ($0 * 100).rounded() }
        guard pose != lastPose else {
            return
        }
        lastPose = pose

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        for sub in [rodLayer, handLayer] {
            sub.shadowOffset = shadowOffset
            sub.shadowRadius = max(1, lift * 0.35) + 5 * pressAmount
            // The hand always casts a shadow.
            sub.shadowOpacity = Float(0.26 + 0.02 * pressAmount)
        }

        rodLayer.bounds = CGRect(x: 0, y: 0, width: widthPts, height: rodLen)
        rodLayer.position = CGPoint(x: widthPts / 2, y: 0)
        handLayer.bounds = CGRect(x: 0, y: 0, width: widthPts, height: handPts)
        handLayer.position = CGPoint(x: widthPts / 2, y: rodLen)

        group.bounds = CGRect(x: 0, y: 0, width: widthPts, height: rodLen + handPts)
        grow.bounds = group.bounds
        grow.position = CGPoint(x: widthPts / 2, y: 0)
        group.position = grip
        group.transform = CATransform3DMakeRotation(rotation, 0, 0, 1)

        CATransaction.commit()
    }

    private func currentLift(_ screenH: CGFloat) -> CGFloat {
        liftFrac * screenH * (1 - 0.8 * pressAmount)
    }

    private func aimStroke(cursor: CGPoint) {
        let r = CGFloat(Preferences.strokeSize) / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        brushLayer.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r), transform: nil)
        brushLayer.fillColor = ink.tapColor
        brushLayer.opacity = Float(Preferences.inkOpacity) / 100
        brushLayer.position = cursor
        CATransaction.commit()
    }

    private func updateDisplayImage(_ a: HandAsset) {
        let full = a.image
        let scale = window?.backingScaleFactor ?? 2
        let restPts = handLenFrac * bounds.height / (a.wrist - a.handTop)
        let step = 64
        let needed = (Int((restPts * scale).rounded(.up)) + step - 1) / step * step
        let height = needed >= full.height * 9 / 10 ? full.height : max(step, needed)
        guard height != displayImageHeight else {
            return
        }
        displayImageHeight = height
        let image = height == full.height ? full : HandAsset.resized(full, height: height) ?? full
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rodLayer.contents = image
        handLayer.contents = image
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        applyBackingScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyBackingScale()
    }

    private func applyBackingScale() {
        let scale = window?.backingScaleFactor ?? 2
        rodLayer.contentsScale = scale
        handLayer.contentsScale = scale
        screenInk.scale = scale
        targetInk?.scale = scale
    }
}
