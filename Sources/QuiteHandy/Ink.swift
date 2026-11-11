import AppKit
import CoreText

final class Ink {
    let layer = CALayer()
    /// Lines never fade (the whiteboard keeps everything until it is cleared).
    var alwaysKeep = false
    var keep: Bool { alwaysKeep || Preferences.fadeSeconds <= 0 }

    static let purple = CGColor(srgbRed: 0.53, green: 0.33, blue: 0.95, alpha: 1)
    static let red = CGColor(srgbRed: 1.0, green: 0.16, blue: 0.12, alpha: 1)

    static func hex(_ v: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
    var color = Ink.purple
    /// Lines are white with black dashes on top (the glove's ink).
    var zebra = false
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
    /// Rainbow lines drawn since the last clear.
    private var rainbowLines = 0
    /// Hue where the last rainbow line was lifted, in degrees. Taps use it, and the next line
    /// starts from it plus the shift.
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
        // Lines and stamps are flat, without a shadow.
        group.shadowOpacity = 0
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
            // The first line starts at red; each next one starts where the last line ended,
            // shifted by `Preferences.rainbowStep` degrees.
            if rainbowLines == 0 {
                startHue = 0
            } else {
                startHue = (lastRainbowHue + CGFloat(Preferences.rainbowStep)).truncatingRemainder(dividingBy: 360)
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
        let s = zebra && !rainbow ? ZebraLayer() : CAShapeLayer()
        s.strokeColor = zebra && !rainbow ? NSColor.white.cgColor : color
        s.fillColor = nil
        s.lineWidth = width
        s.lineCap = .round
        s.lineJoin = .round
        (s as? ZebraLayer)?.setUp(width: width)
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
        record(.add(s, number: nil))
        if keep {
            return
        }
        fade(s, after: fadeDelay, over: fadeDuration)
    }

    // MARK: Undo and redo

    /// One change to the drawing that can be taken back.
    private enum Step {
        /// A line, or a new stamp with its number.
        case add(CALayer, number: Int?)
        /// A stamp removed with a click.
        case remove(CALayer, number: Int)
        case move(CALayer, from: CGPoint, to: CGPoint)
        /// Stamps that got other numbers (two of them when numbers were swapped).
        case renumber([(layer: CALayer, from: Int, to: Int)])
        /// Everything taken away at once (a new whiteboard sheet).
        case removeAll([(layer: CALayer, number: Int?)])
    }

    /// Told about every new step, so one history can keep the order across several inks.
    var onRecord: ((Ink) -> Void)?

    private var undoSteps: [Step] = []
    private var redoSteps: [Step] = []
    private static let maxSteps = 200

    private func record(_ step: Step) {
        onRecord?(self)
        undoSteps.append(step)
        if undoSteps.count > Ink.maxSteps {
            undoSteps.removeFirst()
        }
        redoSteps = []
    }

    /// Takes back the last line or stamp change. Lines that have already faded are skipped.
    /// False when there was nothing left to take back.
    @discardableResult
    func undo() -> Bool {
        guard stroke == nil, placing == nil else {
            return false
        }
        while let step = undoSteps.popLast() {
            if apply(step, forward: false) {
                redoSteps.append(step)
                return true
            }
        }
        return false
    }

    /// Takes everything away in one step that can be undone.
    func clearUndoably() {
        endStamp()
        let all = (layer.sublayers ?? []).map { l in (layer: l, number: stampList.first { $0.layer === l }?.number) }
        guard !all.isEmpty else {
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for item in all {
            _ = hide(item.layer)
        }
        CATransaction.commit()
        record(.removeAll(all))
    }

    /// Brings back what `undo` took back.
    @discardableResult
    func redo() -> Bool {
        guard stroke == nil, placing == nil else {
            return false
        }
        while let step = redoSteps.popLast() {
            if apply(step, forward: true) {
                undoSteps.append(step)
                return true
            }
        }
        return false
    }

    /// Does (`forward`) or takes back a step. False when it no longer applies, because the
    /// line or stamp has faded away in the meantime.
    private func apply(_ step: Step, forward: Bool) -> Bool {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        switch step {
        case let .add(l, number):
            return forward ? show(l, number: number) : hide(l)
        case let .remove(l, number):
            return forward ? hide(l) : show(l, number: number)
        case let .move(l, from, to):
            guard l.superlayer != nil else {
                return false
            }
            l.position = forward ? to : from
            return true
        case let .removeAll(items):
            var any = false
            for item in items {
                any = (forward ? hide(item.layer) : show(item.layer, number: item.number)) || any
            }
            return any
        case let .renumber(changes):
            guard changes.allSatisfy({ $0.layer.superlayer != nil }) else {
                return false
            }
            setNumbers(changes.map { ($0.layer, forward ? $0.to : $0.from) })
            return true
        }
    }

    private func hide(_ l: CALayer) -> Bool {
        guard l.superlayer != nil else {
            return false
        }
        l.removeFromSuperlayer()
        stampList.removeAll { $0.layer === l }
        return true
    }

    private func show(_ l: CALayer, number: Int?) -> Bool {
        guard l.superlayer == nil else {
            return false
        }
        layer.addSublayer(l)
        if let number = number {
            stampList.append((l, number))
        }
        // Back on screen: with fading lines, it fades again from now on.
        l.removeAnimation(forKey: "fade")
        if !keep {
            fade(l, after: fadeDelay, over: fadeDuration)
        }
        return true
    }

    /// Number stamps on screen, with their numbers.
    private var stampList: [(layer: CALayer, number: Int)] = []
    /// The stamp being placed was already there (it is being moved, or removed on a plain click).
    private var placingExisting = false
    private var placingStart = CGPoint.zero
    private var placingMoved = false
    private var grabOffset = CGPoint.zero
    private var grabbedFrom = CGPoint.zero

    /// Mouse down with the stamp key: grab the stamp under the pointer, or put down a new one.
    /// False when nothing happens: all nine numbers are already on screen.
    @discardableResult
    func pressStamp(at point: CGPoint) -> Bool {
        endStamp()
        stampList.removeAll { $0.layer.superlayer == nil }
        placingStart = point
        placingMoved = false
        if let hit = stamp(at: point) {
            placing = hit
            placingExisting = true
            grabbedFrom = hit.position
            grabOffset = CGPoint(x: hit.position.x - point.x, y: hit.position.y - point.y)
            return true
        }
        guard stampList.count < Ink.maxStamps else {
            return false
        }
        // Count up; once past 9, carry on with the smallest number that is free again.
        let next = (stampList.map(\.number).max() ?? 0) + 1
        let number = next <= Ink.maxStamps ? next
            : (1...Ink.maxStamps).first { n in !stampList.contains { $0.number == n } } ?? Ink.maxStamps
        placingExisting = false
        grabOffset = .zero
        beginStamp(at: point, number: number)
        return true
    }

    /// Only single digits: at most nine stamps, numbered up to 9.
    static let maxStamps = 9
    private static let stampDiameter: CGFloat = 42
    private static let maxStampDiameter: CGFloat = 200
    /// Holding still on a new stamp makes it grow after this long, to the largest size in `growTime`.
    private static let growDelay: TimeInterval = 0
    private static let growTime: TimeInterval = 1.6
    private var growTimer: Timer?
    /// Called when a growing stamp reached its largest size and was put down on its own.
    var onStampPopped: (() -> Void)?

    /// The stamp under `point`, if any.
    func stamp(at point: CGPoint) -> CALayer? {
        stampList.last(where: {
            $0.layer.superlayer != nil
                && hypot($0.layer.position.x - point.x, $0.layer.position.y - point.y) <= $0.layer.bounds.width / 2
        })?.layer
    }

    /// Gives the stamp under `point` the number `number` (numbers may repeat).
    func renumberStamp(at point: CGPoint, to number: Int) {
        guard (1...Ink.maxStamps).contains(number), let target = stamp(at: point),
              let index = stampList.firstIndex(where: { $0.layer === target }) else {
            return
        }
        let old = stampList[index].number
        guard old != number else {
            return
        }
        let changes = [(target, old, number)]
        setNumbers(changes.map { ($0.0, $0.2) })
        record(.renumber(changes.map { (layer: $0.0, from: $0.1, to: $0.2) }))
    }

    private func setNumbers(_ numbers: [(CALayer, Int)]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (l, n) in numbers {
            if let i = stampList.firstIndex(where: { $0.layer === l }) {
                stampList[i].number = n
            }
            drawStamp(l, number: n)
        }
        CATransaction.commit()
    }

    /// The stamp being placed: it follows the mouse until the button is released.
    private var placing: CALayer?

    /// Puts down a number stamp – a filled circle in the current ink colour and line opacity, with
    /// a Fredoka number (weight 600) – and lets it follow the mouse. Held still, it grows.
    func beginStamp(at point: CGPoint, number stampNumber: Int) {
        // Same colour the next line would have (rainbow: where the last line ended).
        let fill = tapColor.copy(alpha: CGFloat(Preferences.inkOpacity) / 100) ?? tapColor

        let group = CALayer()
        group.position = point
        group.shadowColor = NSColor.black.cgColor
        group.shadowOpacity = 0
        group.shadowRadius = 2
        group.shadowOffset = CGSize(width: 1, height: -2)
        group.setValue(fill, forKey: "stampFill")
        group.setValue(Ink.stampDiameter, forKey: "stampDiameter")

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        drawStamp(group, number: stampNumber)
        layer.addSublayer(group)
        CATransaction.commit()
        placing = group
        stampList.append((group, stampNumber))
        startGrowing(group)
    }

    /// (Re)draws a stamp's circle and number at its current diameter.
    private func drawStamp(_ group: CALayer, number stampNumber: Int) {
        let diameter = group.value(forKey: "stampDiameter") as? CGFloat ?? Ink.stampDiameter
        let fill = (group.value(forKey: "stampFill") as! CGColor?) ?? tapColor
        let wasRasterized = group.shouldRasterize
        group.shouldRasterize = false
        group.sublayers?.forEach { $0.removeFromSuperlayer() }
        group.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        let circle = CAShapeLayer()
        circle.path = CGPath(ellipseIn: group.bounds, transform: nil)
        circle.fillColor = fill
        group.addSublayer(circle)

        // The number as an outline, centred on its real ink bounds.
        let text = "\(stampNumber)"
        let font = Ink.stampFont(size: diameter * 28 / Ink.stampDiameter)
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
        let optical: CGFloat = text == "1" ? -2 * diameter / Ink.stampDiameter : 0
        var move = CGAffineTransform(translationX: diameter / 2 - box.midX + optical, y: diameter / 2 - box.midY)
        let number = CAShapeLayer()
        number.path = digits.copy(using: &move)
        number.fillColor = Ink.contrastColor(on: fill)
        group.addSublayer(number)
        group.shouldRasterize = wasRasterized
    }

    /// While the button stays down on a new stamp, it grows up to `maxStampDiameter`; there it
    /// pops and is put down on its own.
    private func startGrowing(_ group: CALayer) {
        growTimer?.invalidate()
        let start = Date().addingTimeInterval(Ink.growDelay)
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self, weak group] t in
            guard let self = self, let group = group, self.placing === group, !self.placingExisting else {
                t.invalidate()
                return
            }
            let elapsed = Date().timeIntervalSince(start)
            guard elapsed > 0 else {
                return
            }
            let progress = min(1, CGFloat(elapsed / Ink.growTime))
            // Linear, so the stamp visibly grows right from the start.
            let eased = progress
            let diameter = Ink.stampDiameter + (Ink.maxStampDiameter - Ink.stampDiameter) * eased
            group.setValue(diameter, forKey: "stampDiameter")
            if let number = self.stampList.first(where: { $0.layer === group })?.number {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.drawStamp(group, number: number)
                CATransaction.commit()
            }
            if progress >= 1 {
                t.invalidate()
                let pop = CAKeyframeAnimation(keyPath: "transform.scale")
                pop.values = [1, 1.12, 1]
                pop.keyTimes = [0, 0.4, 1]
                pop.duration = 0.25
                group.add(pop, forKey: "pop")
                self.endStamp()
                self.onStampPopped?()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        growTimer = timer
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

    /// Fredoka at weight 600 (it ships as a variable font).
    private static func stampFont(size: CGFloat) -> CTFont {
        let base = CTFontCreateWithName("Fredoka" as CFString, size, nil)
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
        growTimer?.invalidate()
        growTimer = nil
        guard let group = placing else {
            return
        }
        placing = nil
        if placingExisting {
            // A plain click on a stamp removes it; dragging it just moved it.
            if !placingMoved {
                let number = stampList.first { $0.layer === group }?.number ?? 0
                group.removeFromSuperlayer()
                stampList.removeAll { $0.layer === group }
                record(.remove(group, number: number))
            } else {
                record(.move(group, from: grabbedFrom, to: group.position))
            }
            placingExisting = false
            return
        }
        group.rasterizationScale = scale
        group.shouldRasterize = true
        record(.add(group, number: stampList.first { $0.layer === group }?.number))
        if !keep {
            fade(group, after: fadeDelay, over: fadeDuration)
        }
    }

    var isPlacingStamp: Bool { placing != nil }

    func clear() {
        placing = nil
        stampList = []
        undoSteps = []
        redoSteps = []
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
        // A line brought back with redo fades again; only its latest fade may remove it.
        let token = UUID()
        s.setValue(token, forKey: "fadeToken")
        s.add(anim, forKey: "fade")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + duration) { [weak s] in
            guard let s = s, s.value(forKey: "fadeToken") as? UUID == token else {
                return
            }
            s.removeFromSuperlayer()
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


/// A white line with black dashes on top, both following the same path.
private final class ZebraLayer: CAShapeLayer {
    private let dashes = CAShapeLayer()

    override init() {
        super.init()
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    func setUp(width: CGFloat) {
        dashes.strokeColor = NSColor.black.cgColor
        dashes.fillColor = nil
        dashes.lineWidth = width
        dashes.lineCap = .butt
        dashes.lineJoin = .round
        let dash = max(4, width * 1.6) as NSNumber
        dashes.lineDashPattern = [dash, dash]
        addSublayer(dashes)
    }

    override var path: CGPath? {
        didSet {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            dashes.path = path
            CATransaction.commit()
        }
    }
}
