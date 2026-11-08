import AppKit
import CoreText

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
    /// Hue where the last rainbow line was lifted, in degrees. Taps use it, and with a shift of 0°
    /// the next line carries on from it.
    private var lastRainbowHue: CGFloat = 0

    /// Colour for the tap circle: with rainbow ink the colour where the last line ended
    /// (red before the first one), otherwise the ink colour.
    var tapColor: CGColor {
        guard Preferences.inkChoice == .rainbow else {
            return color
        }
        return Ink.rainbowColor(at: 0, startHue: lastRainbowHue)
    }
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
        even = [point]
        window = Preferences.strokeSmoothing.window
        lastRaw = point
        settled = 1
        lastSettled = point
        tail = nil
        self.width = width
        rainbow = Preferences.inkChoice == .rainbow
        let arrowFlags = Preferences.arrowKey.cgFlags
        arrow = (!arrowFlags.isEmpty && CGEventSource.flagsState(.hidSystemState).contains(arrowFlags))
            || ProcessInfo.processInfo.environment["TH_ARROW"] != nil  // for --render-test
        head = nil
        if arrow {
            // Arrows always get the strongest smoothing, so the line and its head read cleanly.
            window = StrokeSmoothing.allCases.last?.window ?? window
        }
        if rainbow {
            if Preferences.rainbowStep == 0 {
                // No shift: keep drawing in the colour the last line ended with.
                startHue = lastRainbowHue
            } else {
                startHue = CGFloat((rainbowLines * Preferences.rainbowStep) % 360)
            }
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

    // Smoothing: the line always ends exactly at the mouse, but the part already drawn is
    // smoothed afterwards while you drag. The mouse path is resampled to even steps and every
    // point is replaced by a weighted average of its neighbours; near the ends the window
    // shrinks, so the start and the pen tip stay where they are.
    private static let spacing: CGFloat = 3
    /// Drawing a straight arrow (the arrow key was held when the line started).
    private var arrow = false

    private var even: [CGPoint] = []
    private var window = 0
    private var lastRaw = CGPoint.zero
    /// Rainbow: resampled points already turned into coloured pieces (they no longer change).
    private var settled = 0
    private var lastSettled = CGPoint.zero
    /// Rainbow: the end of the line that is still being smoothed, redrawn on every move.
    private var tail: CAShapeLayer?

    /// The open chevron at the end of an arrow line.
    private var head: CAShapeLayer?

    /// The line as it is drawn right now, from start to the pen tip.
    private func currentLine() -> [CGPoint] {
        window > 0 ? smoothedLine() : points
    }

    /// Draws the arrowhead at the end of the line, pointing the way the line was last going.
    private func updateHead() {
        guard arrow, let group = stroke else {
            return
        }
        let line = currentLine()
        guard let tip = line.last, line.count > 1 else {
            return
        }
        let size = max(14, width * 2.6)
        // Direction: from a point a little way back along the line to the tip, so it doesn't jitter.
        var back = line[0]
        var travelled: CGFloat = 0
        for i in stride(from: line.count - 1, to: 0, by: -1) {
            travelled += hypot(line[i].x - line[i - 1].x, line[i].y - line[i - 1].y)
            back = line[i - 1]
            if travelled >= size {
                break
            }
        }
        let dx = back.x - tip.x
        let dy = back.y - tip.y
        guard hypot(dx, dy) > 2 else {
            return
        }
        let angle = atan2(dy, dx)
        let spread = CGFloat.pi / 6.5
        let path = CGMutablePath()
        path.move(to: CGPoint(x: tip.x + cos(angle + spread) * size, y: tip.y + sin(angle + spread) * size))
        path.addLine(to: tip)
        path.addLine(to: CGPoint(x: tip.x + cos(angle - spread) * size, y: tip.y + sin(angle - spread) * size))
        let h: CAShapeLayer
        if let existing = head {
            h = existing
        } else {
            h = makeShape(color: color)
            group.addSublayer(h)
            head = h
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        h.strokeColor = rainbow ? Ink.rainbowColor(at: totalLength, startHue: startHue, cycle: cycle) : color
        h.path = path
        CATransaction.commit()
    }

    func extend(to raw: CGPoint) {
        guard stroke != nil else {
            return
        }
        lastRaw = raw
        defer { updateHead() }
        guard window > 0 else {
            add(raw)
            return
        }
        resample(to: raw)
        if rainbow {
            settleRainbow(final: false)
        } else {
            redraw(smoothedLine())
        }
    }

    private func resample(to p: CGPoint) {
        guard var last = even.last else {
            even = [p]
            return
        }
        var d = hypot(p.x - last.x, p.y - last.y)
        while d >= Ink.spacing {
            let t = Ink.spacing / d
            last = CGPoint(x: last.x + (p.x - last.x) * t, y: last.y + (p.y - last.y) * t)
            even.append(last)
            d = hypot(p.x - last.x, p.y - last.y)
        }
    }

    /// Triangle-weighted average of the neighbours of resampled point `i`.
    private func smoothedPoint(_ i: Int) -> CGPoint {
        let k = min(window, i, even.count - 1 - i)
        guard k > 0 else {
            return even[i]
        }
        var x: CGFloat = 0, y: CGFloat = 0, total: CGFloat = 0
        for j in (i - k)...(i + k) {
            let w = CGFloat(k + 1 - abs(j - i))
            x += even[j].x * w
            y += even[j].y * w
            total += w
        }
        return CGPoint(x: x / total, y: y / total)
    }

    private func smoothedLine() -> [CGPoint] {
        (0..<even.count).map(smoothedPoint) + [lastRaw]
    }

    /// Hands every point that can no longer change to the rainbow pieces, and redraws the tail.
    private func settleRainbow(final: Bool) {
        let limit = final ? even.count : even.count - window
        while settled < limit {
            let p = smoothedPoint(settled)
            extendRainbow(from: lastSettled, to: p)
            lastSettled = p
            settled += 1
        }
        if final {
            extendRainbow(from: lastSettled, to: lastRaw)
            tail?.removeFromSuperlayer()
            tail = nil
            return
        }
        let t: CAShapeLayer
        if let existing = tail {
            t = existing
        } else {
            t = makeShape(color: color)
            stroke?.addSublayer(t)
            tail = t
        }
        let path = CGMutablePath()
        path.move(to: lastSettled)
        for i in settled..<even.count {
            path.addLine(to: smoothedPoint(i))
        }
        path.addLine(to: lastRaw)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        t.strokeColor = Ink.rainbowColor(at: totalLength, startHue: startHue, cycle: cycle)
        t.path = path
        CATransaction.commit()
    }

    private func add(_ point: CGPoint) {
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
        if window > 0 && even.count > 1 {
            if rainbow {
                settleRainbow(final: true)
            } else {
                redraw(smoothedLine())
            }
        }
        updateHead()
        head = nil
        if rainbow {
            let turns = startHue / 360 + totalLength / cycle
            lastRainbowHue = (turns - turns.rounded(.down)) * 360
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

    /// Number stamps on screen, with their numbers.
    private var stampList: [(layer: CALayer, number: Int)] = []
    /// The stamp being placed was already there (it is being moved, or removed on a plain click).
    private var placingExisting = false
    private var placingStart = CGPoint.zero
    private var placingMoved = false
    private var grabOffset = CGPoint.zero

    /// Mouse down with the stamp key: grab the stamp under the pointer, or put down a new one.
    func pressStamp(at point: CGPoint) {
        endStamp()
        stampList.removeAll { $0.layer.superlayer == nil }
        placingStart = point
        placingMoved = false
        if let hit = stampList.last(where: {
            hypot($0.layer.position.x - point.x, $0.layer.position.y - point.y) <= $0.layer.bounds.width / 2
        }) {
            placing = hit.layer
            placingExisting = true
            grabOffset = CGPoint(x: hit.layer.position.x - point.x, y: hit.layer.position.y - point.y)
            return
        }
        placingExisting = false
        grabOffset = .zero
        beginStamp(at: point)
    }

    /// The stamp being placed: it follows the mouse until the button is released.
    private var placing: CALayer?

    /// Puts down the next number stamp – a filled circle in the current ink colour and line
    /// opacity, with a Playpen Sans number (weight 600) – and lets it follow the mouse.
    func beginStamp(at point: CGPoint) {
        let stampNumber = (stampList.map(\.number).max() ?? 0) + 1
        let text = "\(stampNumber)"
        let diameter: CGFloat = text.count > 2 ? 48 : 42
        // Same colour the next line would have (rainbow: where the last line ended).
        let fill = tapColor.copy(alpha: CGFloat(Preferences.inkOpacity) / 100) ?? tapColor

        let group = CALayer()
        group.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        group.position = point
        group.shadowColor = NSColor.black.cgColor
        group.shadowOpacity = 0.25
        group.shadowRadius = 2
        group.shadowOffset = CGSize(width: 1, height: -2)
        let circle = CAShapeLayer()
        circle.path = CGPath(ellipseIn: group.bounds, transform: nil)
        circle.fillColor = fill
        group.addSublayer(circle)

        // The number as an outline, centred on its real ink bounds.
        let size: CGFloat = text.count > 1 ? 23 : 28
        let font = Ink.stampFont(size: size)
        let digits = CGMutablePath()
        var x: CGFloat = 0
        for unit in text.utf16 {
            var c = unit
            var glyph = CGGlyph()
            CTFontGetGlyphsForCharacters(font, &c, &glyph, 1)
            if let g = CTFontCreatePathForGlyph(font, glyph, nil) {
                digits.addPath(g, transform: CGAffineTransform(translationX: x, y: 0))
            }
            var advance = CGSize.zero
            CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
            x += advance.width
        }
        let box = digits.boundingBoxOfPath
        // A lone "1" looks off-centre to the right (its flag sits on the left), so nudge it left.
        let optical: CGFloat = text == "1" ? -2 : 0
        var move = CGAffineTransform(translationX: diameter / 2 - box.midX + optical, y: diameter / 2 - box.midY)
        let number = CAShapeLayer()
        number.path = digits.copy(using: &move)
        number.fillColor = Ink.contrastColor(on: fill)
        group.addSublayer(number)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.addSublayer(group)
        CATransaction.commit()
        placing = group
        stampList.append((group, stampNumber))
    }

    /// Black or white, whichever contrasts more with `background` (WCAG contrast ratio).
    static func contrastColor(on background: CGColor) -> CGColor {
        guard let c = NSColor(cgColor: background)?.usingColorSpace(.sRGB) else {
            return NSColor.black.cgColor
        }
        func linear(_ v: CGFloat) -> CGFloat {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
        let againstWhite = 1.05 / (luminance + 0.05)
        let againstBlack = (luminance + 0.05) / 0.05
        return againstWhite > againstBlack ? NSColor.white.cgColor : NSColor.black.cgColor
    }

    /// Playpen Sans at weight 600 (it ships as a variable font).
    private static func stampFont(size: CGFloat) -> CTFont {
        let base = CTFontCreateWithName("Playpen Sans" as CFString, size, nil)
        let weightAxis = 0x77676874  // 'wght'
        let attributes = [kCTFontVariationAttribute: [weightAxis: 600]] as CFDictionary
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes)
        return CTFontCreateCopyWithAttributes(base, size, nil, descriptor)
    }

    func moveStamp(to point: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if hypot(point.x - placingStart.x, point.y - placingStart.y) > 4 {
            placingMoved = true
        }
        placing?.position = CGPoint(x: point.x + grabOffset.x, y: point.y + grabOffset.y)
        CATransaction.commit()
    }

    func endStamp() {
        guard let group = placing else {
            return
        }
        placing = nil
        if placingExisting {
            // A plain click on a stamp removes it; dragging it just moved it.
            if !placingMoved {
                group.removeFromSuperlayer()
                stampList.removeAll { $0.layer === group }
            }
            placingExisting = false
            return
        }
        group.rasterizationScale = scale
        group.shouldRasterize = true
        if !keep {
            fade(group, after: fadeDelay, over: fadeDuration)
        }
    }

    var isPlacingStamp: Bool { placing != nil }

    func clear() {
        placing = nil
        stampList = []
        rainbowLines = 0
        lastRainbowHue = 0
        stroke = nil
        piece = nil
        tail = nil
        head = nil
        points = []
        even = []
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

    private func redraw(_ line: [CGPoint]? = nil) {
        let points = line ?? self.points
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
