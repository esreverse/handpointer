import AppKit
import CoreMedia
import ScreenCaptureKit

/// A round loupe that follows the pointer and shows the screen magnified while the zoom key is held.
///
/// At 1× it is a flashlight instead: no loupe window and no capture, only the screen darkened
/// around the pointer, so it works without Screen Recording permission.
///
/// The screen is captured with ScreenCaptureKit (needs Screen Recording permission). HandPointer's own
/// windows are left out of the capture, so the hand, the ink and the toolbar never show up inside it.
/// Capture starts when the key is first held and stops a few seconds after the loupe has closed.
final class Magnifier: NSObject, SCStreamOutput, SCStreamDelegate {
    /// The loupe has its own window above the toolbar, so its ring can be Liquid Glass.
    private let window: NSWindow
    private let host = NSView()
    private var glass: NSView?
    /// Width of the Liquid Glass ring as a share of the loupe's diameter (10 pt on a 340 pt
    /// loupe), so it grows with the loupe, between 10 and 20 pt.
    private static let ringShare: CGFloat = 10 / 340
    private let layer = CALayer()
    private let content = CALayer()
    /// Black (Preferences.dimAlpha) over the rest of the screen, with a hole where the loupe is.
    /// It is one of our own windows, so the capture leaves it out of the loupe.
    private let dim: NSWindow
    private let dimLayer = CAShapeLayer()

    private var stream: SCStream?
    private var starting = false
    private var streamDisplay: CGDirectDisplayID?
    private var hasFrame = false
    private var askedPermission = false
    private let queue = DispatchQueue(label: "handpointer.magnifier")

    private var zoom: CGFloat = 1
    private var target: CGFloat = 1
    private var animFrom: CGFloat = 1
    private var animStart: CFTimeInterval = 0
    private let animDuration: CFTimeInterval = 0.25
    private var lastHeld = Date.distantPast
    private static let keepStreamFor: TimeInterval = 3

    private var flashOn = false
    /// Set once the loupe has finished opening, until it closes.
    private var fullyOpen = false
    /// Shows the zoom factor while it changes: a pill with a masked tape of half steps that rolls
    /// with the zoom and snaps with it.
    private let badge = CALayer()
    private let tapeClip = CALayer()
    private let tapeFade = CAGradientLayer()
    private let tape = CALayer()
    private static let tapeValues: [CGFloat] = stride(from: 1.0, through: 6.0, by: 0.5).map { CGFloat($0) }
    private static let badgeSize = CGSize(width: 64, height: 28)
    private var shownFactor: CGFloat = 0
    private var badgeUntil = Date.distantPast
    /// When the key went down, for fading the darkening in on its own (not with the loupe), so it
    /// is already there while the capture starts.
    private var heldSince: CFTimeInterval?

    /// While swiping up and down: the factor to show right now, before it snaps to a half step.
    var previewFactor: CGFloat?

    /// While size and zoom are adjusted with the mouse, the loupe stays here instead of following it.
    private var anchor: CGPoint?
    /// After adjusting, the loupe glides from here back to the pointer.
    private var snapFrom: CGPoint?
    private var snapStart: CFTimeInterval = 0
    private static let snapDuration: CFTimeInterval = 0.35

    /// Holds the loupe at `point` (global coordinates); nil lets it glide back to the pointer.
    func setAnchor(_ point: CGPoint?) {
        if point == nil, let held = anchor {
            snapFrom = held
            snapStart = CACurrentMediaTime()
        }
        anchor = point
    }

    /// Where the loupe is drawn: the anchor while adjusting, then an ease-out back to the pointer.
    private func center(for mouse: CGPoint) -> CGPoint {
        if let a = anchor {
            return a
        }
        guard let from = snapFrom else {
            return mouse
        }
        let t = min(1, (CACurrentMediaTime() - snapStart) / Magnifier.snapDuration)
        if t >= 1 {
            snapFrom = nil
            return mouse
        }
        let e = CGFloat(1 - pow(1 - t, 3))
        return CGPoint(x: from.x + (mouse.x - from.x) * e, y: from.y + (mouse.y - from.y) * e)
    }
    private let badgeWindow: NSWindow = {
        let w = NSWindow(contentRect: CGRect(origin: .zero, size: CGSize(width: 64, height: 28)),
                         styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        w.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 4)
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        return w
    }()
    private var flashStart: CFTimeInterval = 0

    /// True while the loupe or flashlight is open or animating, so the overlay keeps updating at full speed.
    var isBusy: Bool { target > 1 || zoom > 1.001 || flashOn || heldSince != nil || snapFrom != nil }

    /// True while the loupe or the flashlight is on screen.
    var isShowing: Bool { window.isVisible || flashOn }

    override init() {
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 240, height: 240),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 3)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        dim = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
                       styleMask: .borderless, backing: .buffered, defer: false)
        dim.isOpaque = false
        dim.backgroundColor = .clear
        dim.hasShadow = false
        dim.ignoresMouseEvents = true
        dim.isReleasedWhenClosed = false
        dim.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        dim.collectionBehavior = window.collectionBehavior
        super.init()
        let dimView = NSView()
        dimView.wantsLayer = true
        dimView.layer = CALayer()
        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.2).cgColor
        dimView.layer?.addSublayer(dimLayer)
        dim.contentView = dimView
        host.layer = CALayer()
        host.wantsLayer = true
        host.layer?.addSublayer(layer)
        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView()
            g.style = .regular
            g.contentView = host
            window.contentView = g
            glass = g
        } else {
            window.contentView = host
        }
        layer.masksToBounds = false
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.35
        layer.shadowRadius = 10
        layer.shadowOffset = CGSize(width: 0, height: -3)
        content.masksToBounds = true
        content.contentsGravity = .resize
        content.magnificationFilter = .linear
        content.borderColor = NSColor.black.cgColor
        content.borderWidth = 2
        content.backgroundColor = NSColor.black.cgColor
        layer.addSublayer(content)
        let bs = Magnifier.badgeSize
        badge.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        badge.opacity = 0
        badge.cornerRadius = bs.height / 2
        badge.masksToBounds = true
        tapeClip.frame = CGRect(origin: .zero, size: bs)
        tapeClip.masksToBounds = true
        // Soft top and bottom edges, so the numbers roll in and out of view.
        tapeFade.frame = tapeClip.bounds
        tapeFade.colors = [NSColor.clear.cgColor, NSColor.white.cgColor, NSColor.white.cgColor, NSColor.clear.cgColor]
        tapeFade.locations = [0, 0.3, 0.7, 1]
        tapeClip.mask = tapeFade
        for (i, value) in Magnifier.tapeValues.enumerated() {
            let t = CATextLayer()
            t.string = Magnifier.factorText(value)
            t.fontSize = 15
            t.font = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
            t.foregroundColor = NSColor.white.cgColor
            t.alignmentMode = .center
            t.contentsScale = 2
            t.frame = CGRect(x: 0, y: 5 - CGFloat(i) * bs.height, width: bs.width, height: 20)
            tape.addSublayer(t)
        }
        tapeClip.addSublayer(tape)
        badge.addSublayer(tapeClip)
        // The pill has its own window above the loupe, so it stays visible at 1× without a ring.
        let badgeView = NSView(frame: CGRect(origin: .zero, size: bs))
        badgeView.wantsLayer = true
        badgeView.layer = CALayer()
        badge.frame = CGRect(origin: .zero, size: bs)
        badgeView.layer?.addSublayer(badge)
        badgeWindow.contentView = badgeView
    }

    /// Call on every overlay tick. `mouse` is in global screen coordinates.
    func update(held: Bool, mouse pointer: CGPoint, screen: NSScreen) {
        if !held {
            anchor = nil
            snapFrom = nil
        }
        let mouse = center(for: pointer)
        let factor = previewFactor ?? CGFloat(Preferences.effectiveZoom)
        if held {
            heldSince = heldSince ?? CACurrentMediaTime()
        } else {
            heldSince = nil
        }
        if Preferences.isFlashlight && previewFactor == nil {
            updateFlashlight(held: held, mouse: mouse, screen: screen)
            return
        }
        flashOn = false
        if held {
            lastHeld = Date()
            ensureStream(for: screen)
        }
        let newTarget: CGFloat = held ? factor : 1
        if held && fullyOpen && (previewFactor != nil || factor != shownFactor) {
            badgeUntil = Date().addingTimeInterval(1)
        }
        shownFactor = factor
        if newTarget != target {
            animFrom = zoom
            target = newTarget
            animStart = CACurrentMediaTime()
        }
        if held && !hasFrame {
            // Wait with the zoom-in until the first frame is there.
            animStart = CACurrentMediaTime()
        }

        if !held {
            // Only zooming in is animated; letting go closes the loupe at once.
            zoom = 1
            animFrom = 1
        } else if previewFactor != nil && fullyOpen {
            // Swiping: the zoom follows the finger; it glides only when it snaps after letting go.
            zoom = target
            animFrom = target
        } else {
            // Opening, and changing the factor while the loupe is open, always glides.
            let t = min(1, max(0, (CACurrentMediaTime() - animStart) / animDuration))
            let eased = CGFloat(1 - pow(1 - t, 3))
            zoom = animFrom + (target - animFrom) * eased
        }

        let visible = hasFrame && (held || zoom > 1.001)
        layout(mouse: mouse, screen: screen, visible: visible, held: held, factor: factor)

        if !held && zoom <= 1.001 && stream != nil && Date().timeIntervalSince(lastHeld) > Magnifier.keepStreamFor {
            stopStream()
        }
    }

    /// The flashlight: darkens everything but a circle around the pointer, fading in while held.
    private func updateFlashlight(held: Bool, mouse: CGPoint, screen: NSScreen) {
        if stream != nil {
            stopStream()
        }
        target = 1
        zoom = 1
        animFrom = 1
        fullyOpen = false
        if window.isVisible {
            window.orderOut(nil)
        }
        if badgeWindow.isVisible {
            badgeWindow.orderOut(nil)
        }
        if held && !flashOn {
            flashStart = CACurrentMediaTime()
        }
        flashOn = held
        guard held else {
            if dim.isVisible {
                dim.orderOut(nil)
            }
            return
        }
        let t = min(1, max(0, (CACurrentMediaTime() - flashStart) / animDuration))
        let size = CGFloat(Preferences.loupeSize)
        let spot = CGRect(x: mouse.x - size / 2, y: mouse.y - size / 2, width: size, height: size)
        layoutDim(screen: screen.frame, loupe: spot, alpha: CGFloat(1 - pow(1 - t, 3)))
    }

    /// Close the loupe at once and stop capturing.
    func reset() {
        heldSince = nil
        previewFactor = nil
        flashOn = false
        fullyOpen = false
        target = 1
        zoom = 1
        animFrom = 1
        setHidden(true)
        dim.orderOut(nil)
        badgeWindow.orderOut(nil)
        stopStream()
    }

    private func setHidden(_ hidden: Bool) {
        guard window.isVisible == hidden else {
            return
        }
        if hidden {
            window.orderOut(nil)
            dim.orderOut(nil)
            badgeWindow.orderOut(nil)
        } else {
            window.orderFrontRegardless()
        }
    }

    /// Darkens everything but the loupe at `loupe` (global coordinates) on `screen`.
    private func layoutDim(screen: CGRect, loupe: CGRect, alpha: CGFloat) {
        if dim.frame != screen {
            dim.setFrame(screen, display: false)
        }
        let path = CGMutablePath()
        path.addRect(CGRect(origin: .zero, size: screen.size))
        path.addEllipse(in: loupe.offsetBy(dx: -screen.minX, dy: -screen.minY))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dimLayer.fillColor = NSColor.black.withAlphaComponent(CGFloat(Preferences.dimAlpha)).cgColor
        dimLayer.frame = CGRect(origin: .zero, size: screen.size)
        dimLayer.path = path
        CATransaction.commit()
        dim.alphaValue = alpha
        if !dim.isVisible {
            dim.orderFrontRegardless()
        }
    }

    /// The darkening fades in from when the key went down, on its own.
    private var dimFade: CGFloat {
        guard let since = heldSince else {
            return 1
        }
        let t = min(1, max(0, (CACurrentMediaTime() - since) / animDuration))
        return CGFloat(1 - pow(1 - t, 3))
    }

    static func factorText(_ value: CGFloat) -> String {
        value == value.rounded() ? "\(Int(value))×" : String(format: "%.1f×", Double(value))
    }

    private func layout(mouse: CGPoint, screen: NSScreen, visible: Bool, held: Bool, factor: CGFloat) {
        let frame = screen.frame
        let size = CGFloat(Preferences.loupeSize)
        guard visible else {
            fullyOpen = false
            badgeUntil = .distantPast
            badge.opacity = 0
            if window.isVisible {
                window.orderOut(nil)
            }
            if badgeWindow.isVisible {
                badgeWindow.orderOut(nil)
            }
            if held {
                // Waiting for the first captured frame: the darkening is already there.
                let spot = CGRect(x: mouse.x - size / 2, y: mouse.y - size / 2, width: size, height: size)
                layoutDim(screen: frame, loupe: spot, alpha: dimFade)
            } else if dim.isVisible {
                dim.orderOut(nil)
            }
            return
        }
        let local = CGPoint(x: mouse.x - frame.minX, y: mouse.y - frame.minY)

        // Part of the screen shown in the loupe, in unit coordinates of the captured image
        // (origin at the bottom left, like the overlay view).
        let w = min(1, size / zoom / frame.width)
        let h = min(1, size / zoom / frame.height)
        let u = min(max(0, local.x / frame.width - w / 2), 1 - w)
        let v = min(max(0, local.y / frame.height - h / 2), 1 - h)

        // Fade the ring and shadow in with the zoom, so the loupe grows out of the screen.
        var progress = factor > 1 ? min(1, max(0, (zoom - 1) / (factor - 1))) : 1
        // Once the loupe is fully open it stays opaque: changing the factor while it is open
        // (swiping up and down) must not fade the ring and the darkening out and in again.
        if progress >= 1 {
            fullyOpen = true
        } else if fullyOpen {
            progress = 1
        }

        // Between 1× and 1.5× the ring (and shadow) fades with the zoom: at 1× the loupe is just
        // the flashlight, while the capture keeps running for a seamless way back up.
        let ringAmount = min(1, max(0, (zoom - 1) / 0.5))
        progress *= ringAmount

        let ring = glass == nil ? 0 : min(20, max(10, size * Magnifier.ringShare))
        let loupeFrame = CGRect(x: mouse.x - size / 2, y: mouse.y - size / 2, width: size, height: size)
        // The glass ring sits outside the circle, and the darkening leaves it out too, so the ring
        // shows the undimmed screen behind it. Both grow with the ring as it fades in.
        let outerFrame = loupeFrame.insetBy(dx: -ring, dy: -ring)
        window.setFrame(outerFrame, display: false)
        let hole = loupeFrame.insetBy(dx: -ring * ringAmount, dy: -ring * ringAmount)
        layoutDim(screen: frame, loupe: hole, alpha: dimFade)
        if #available(macOS 26.0, *), let g = glass as? NSGlassEffectView {
            g.cornerRadius = outerFrame.width / 2
        }
        // Grow out of the screen: ring and shadow fade in with the zoom.
        window.alphaValue = glass == nil ? 1 : progress

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = CGRect(x: ring, y: ring, width: size, height: size)
        let inner = layer.bounds.width
        layer.shadowPath = CGPath(ellipseIn: layer.bounds, transform: nil)
        layer.shadowOpacity = glass == nil ? Float(0.35 * progress) : 0
        content.frame = layer.bounds
        content.cornerRadius = inner / 2
        content.borderWidth = glass == nil ? max(2, size * 2 / 340) : 0
        content.borderColor = NSColor(white: 0, alpha: progress).cgColor
        content.contentsRect = CGRect(x: u, y: v, width: w, height: h)
        let bs = Magnifier.badgeSize
        badgeWindow.setFrameOrigin(CGPoint(x: loupeFrame.minX + (size - bs.width) / 2,
                                           y: loupeFrame.minY + max(16, size * 0.06)))
        // The tape shows the zoom as it is on screen, so it rolls while swiping and snaps with the glide.
        let shown = fullyOpen ? zoom : factor
        let index = (shown - Magnifier.tapeValues[0]) / 0.5
        tape.frame = CGRect(x: 0, y: index * bs.height, width: bs.width, height: bs.height)
        CATransaction.commit()
        let badgeOpacity: Float = Date() < badgeUntil ? 1 : 0
        if badge.opacity != badgeOpacity {
            CATransaction.begin()
            CATransaction.setAnimationDuration(badgeOpacity > 0 ? 0.1 : 0.3)
            badge.opacity = badgeOpacity
            CATransaction.commit()
        }
        setHidden(false)
        if !badgeWindow.isVisible {
            badgeWindow.orderFrontRegardless()
        }
    }

    // MARK: - Capture

    private func ensureStream(for screen: NSScreen) {
        let display = screen.displayID
        if let current = streamDisplay, current != display {
            stopStream()
        }
        guard stream == nil, !starting, let display = display else {
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            // Never prompt while the pointer is on: the dialog can't be clicked through the overlay.
            // Settings asks for the permission when zoom gets a key.
            if !askedPermission {
                askedPermission = true
                Log.write("zoom: no Screen Recording permission; turn it on in Settings › Zoom")
            }
            return
        }
        starting = true
        let scale = screen.backingScaleFactor
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            DispatchQueue.main.async {
                self?.startStream(content: content, error: error, display: display, scale: scale)
            }
        }
    }

    private func startStream(content: SCShareableContent?, error: Error?, display id: CGDirectDisplayID, scale: CGFloat) {
        starting = false
        guard let content = content, let display = content.displays.first(where: { $0.displayID == id }) else {
            Log.write("zoom: no shareable display \(id): \(error?.localizedDescription ?? "not found")")
            return
        }
        let me = content.applications.filter { $0.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(CGFloat(display.height) * scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 3

        let s = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        } catch {
            Log.write("zoom: could not add stream output: \(error.localizedDescription)")
            return
        }
        stream = s
        streamDisplay = id
        s.startCapture { [weak self] error in
            guard let error = error else {
                return
            }
            Log.write("zoom: capture failed to start: \(error.localizedDescription)")
            DispatchQueue.main.async {
                if self?.stream === s {
                    self?.stream = nil
                    self?.streamDisplay = nil
                }
            }
        }
        Log.write("zoom: capture started on display \(id)")
    }

    private func stopStream() {
        if let s = stream {
            s.stopCapture { _ in }
            Log.write("zoom: capture stopped")
        }
        stream = nil
        streamDisplay = nil
        hasFrame = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.contents = nil
        CATransaction.commit()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else {
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.stream === stream else {
                return
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.content.contents = surface
            CATransaction.commit()
            self.hasFrame = true
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.write("zoom: capture stopped with error: \(error.localizedDescription)")
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.stream === stream else {
                return
            }
            self.stream = nil
            self.streamDisplay = nil
            self.hasFrame = false
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
