import AppKit

final class Ink {
    let layer = CALayer()
    var keep: Bool { Preferences.fadeSeconds <= 0 }

    static let purple = CGColor(srgbRed: 0.53, green: 0.33, blue: 0.95, alpha: 1)
    static let red = CGColor(srgbRed: 1.0, green: 0.16, blue: 0.12, alpha: 1)

    static func hex(_ v: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
    var color = Ink.purple
    var scale: CGFloat = 2
    private var fadeDelay: CFTimeInterval { max(0.5, Preferences.fadeSeconds) }
    private let fadeDuration: CFTimeInterval = 0.6

    /// Length of line, in points, over which a rainbow line runs once through all hues.
    static var rainbowCycle: CGFloat { 40000 / CGFloat(Preferences.rainbowSpeed) }
    /// A rainbow line is cut into pieces this long, each in its own hue.
    private static let rainbowPiece: CGFloat = 4

    /// Container for one line: holds the shadow and opacity; its sublayers draw the line.
    private var stroke: CALayer?
    private var points: [CGPoint] = []

    private var rainbow = false
    private var piece: CAShapeLayer?
    private var piecePath = CGMutablePath()
    private var pieceLength: CGFloat = 0
    private var totalLength: CGFloat = 0
    private var lastMid = CGPoint.zero
    /// Hue in degrees the current rainbow line starts at.
    private var startHue: CGFloat = 0
    /// Cycle length of the current rainbow line, fixed when it starts.
    private var cycle: CGFloat = 8000
    /// Rainbow lines drawn since the last clear; each one starts `Preferences.rainbowStep` degrees further.
    private var rainbowLines = 0
    private var width: CGFloat = 0

    var isDrawing: Bool { stroke != nil }

    init() {
        layer.masksToBounds = false
    }

    func begin(at point: CGPoint, width: CGFloat) {
        let group = CALayer()
        group.allowsGroupOpacity = true
        group.opacity = Float(Preferences.inkOpacity) / 100
        group.shadowColor = NSColor.black.cgColor
        group.shadowOpacity = 0.18
        group.shadowRadius = 1.5
        group.shadowOffset = CGSize(width: 1, height: -1.5)
        layer.addSublayer(group)
        stroke = group
        points = [point]
        self.width = width
        rainbow = Preferences.inkChoice == .rainbow
        if rainbow {
            startHue = CGFloat((rainbowLines * Preferences.rainbowStep) % 360)
            cycle = Ink.rainbowCycle
            rainbowLines += 1
            totalLength = 0
            lastMid = point
            startPiece(at: point)
            let dot = CGMutablePath()
            dot.move(to: point)
            dot.addLine(to: point)
            setPath(dot)
        } else {
            let s = makeShape(color: color)
            group.addSublayer(s)
            piece = s
            redraw()
        }
    }

    private func makeShape(color: CGColor) -> CAShapeLayer {
        let s = CAShapeLayer()
        s.strokeColor = color
        s.fillColor = nil
        s.lineWidth = width
        s.lineCap = .round
        s.lineJoin = .round
        return s
    }

    static func rainbowColor(at length: CGFloat, startHue: CGFloat = 0, cycle: CGFloat = rainbowCycle) -> CGColor {
        let hue = (startHue / 360 + length / cycle).truncatingRemainder(dividingBy: 1)
        return NSColor(hue: hue, saturation: 1, brightness: 1, alpha: 1).cgColor
    }

    private func startPiece(at point: CGPoint) {
        let s = makeShape(color: Ink.rainbowColor(at: totalLength, startHue: startHue, cycle: cycle))
        stroke?.addSublayer(s)
        piece = s
        piecePath = CGMutablePath()
        piecePath.move(to: point)
        pieceLength = 0
    }

    private func setPath(_ path: CGPath) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        piece?.path = path
        CATransaction.commit()
    }

    private func extendRainbow(from prev: CGPoint, to point: CGPoint) {
        let mid = CGPoint(x: (prev.x + point.x) / 2, y: (prev.y + point.y) / 2)
        piecePath.addQuadCurve(to: mid, control: prev)
        let length = hypot(prev.x - lastMid.x, prev.y - lastMid.y) + hypot(mid.x - prev.x, mid.y - prev.y)
        pieceLength += length
        totalLength += length
        lastMid = mid
        if pieceLength >= Ink.rainbowPiece {
            setPath(piecePath)
            startPiece(at: mid)
        }
        let shown = piecePath.mutableCopy() ?? CGMutablePath()
        shown.addLine(to: point)
        setPath(shown)
    }

    func extend(to point: CGPoint) {
        guard stroke != nil, let last = points.last else {
            return
        }
        if hypot(point.x - last.x, point.y - last.y) < 1.5 {
            return
        }
        points.append(point)
        if rainbow {
            extendRainbow(from: last, to: point)
        } else {
            redraw()
        }
    }

    func end() {
        guard let s = stroke else {
            return
        }
        stroke = nil
        piece = nil
        points = []
        freeze(s)
        if keep {
            return
        }
        fade(s, after: fadeDelay, over: fadeDuration)
    }

    func clear() {
        rainbowLines = 0
        stroke = nil
        piece = nil
        points = []
        layer.sublayers?.forEach { $0.removeFromSuperlayer() }
    }

    private func freeze(_ s: CALayer) {
        let shapes = (s.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
        let boxes = shapes.compactMap { $0.path?.boundingBoxOfPath }
        guard let first = boxes.first else {
            return
        }
        let bounds = boxes.dropFirst().reduce(first) { $0.union($1) }
        let pad = width / 2 + s.shadowRadius * 3 + max(abs(s.shadowOffset.width), abs(s.shadowOffset.height)) + 2
        let box = bounds.insetBy(dx: -pad, dy: -pad).integral
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        s.bounds = box
        s.position = CGPoint(x: box.midX, y: box.midY)
        s.rasterizationScale = scale
        s.shouldRasterize = true
        CATransaction.commit()
    }

    private func fade(_ s: CALayer, after delay: CFTimeInterval, over duration: CFTimeInterval) {
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = s.opacity
        anim.toValue = 0
        anim.beginTime = CACurrentMediaTime() + delay
        anim.duration = duration
        anim.timingFunction = CAMediaTimingFunction(name: .easeIn)
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false
        s.add(anim, forKey: "fade")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + duration) { [weak s] in
            s?.removeFromSuperlayer()
        }
    }

    private func redraw() {
        guard let s = piece, let first = points.first else {
            return
        }
        let path = CGMutablePath()
        path.move(to: first)
        if points.count == 1 {
            path.addLine(to: first)
        }
        for i in 1..<max(1, points.count) {
            let p = points[i]
            let prev = points[i - 1]
            let mid = CGPoint(x: (prev.x + p.x) / 2, y: (prev.y + p.y) / 2)
            path.addQuadCurve(to: mid, control: prev)
        }
        if points.count > 1, let last = points.last {
            path.addLine(to: last)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        s.path = path
        CATransaction.commit()
    }
}
