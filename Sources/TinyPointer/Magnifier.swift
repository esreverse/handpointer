import AppKit
import CoreMedia
import ScreenCaptureKit

/// A round loupe that follows the pointer and shows the screen magnified while the zoom key is held.
///
/// The screen is captured with ScreenCaptureKit (needs Screen Recording permission). TinyPointer's own
/// windows are left out of the capture, so the hand, the ink and the toolbar never show up inside it.
/// Capture starts when the key is first held and stops a few seconds after the loupe has closed.
final class Magnifier: NSObject, SCStreamOutput, SCStreamDelegate {
    /// The loupe has its own window above the toolbar, so its ring can be Liquid Glass.
    private let window: NSWindow
    private let host = NSView()
    private var glass: NSView?
    /// Width of the Liquid Glass ring around the magnified view.
    private static let ring: CGFloat = 10
    private let layer = CALayer()
    private let content = CALayer()

    private var stream: SCStream?
    private var starting = false
    private var streamDisplay: CGDirectDisplayID?
    private var hasFrame = false
    private var askedPermission = false
    private let queue = DispatchQueue(label: "tinypointer.magnifier")

    private var zoom: CGFloat = 1
    private var target: CGFloat = 1
    private var animFrom: CGFloat = 1
    private var animStart: CFTimeInterval = 0
    private let animDuration: CFTimeInterval = 0.25
    private var lastHeld = Date.distantPast
    private static let keepStreamFor: TimeInterval = 3

    /// True while the loupe is open or animating, so the overlay keeps updating at full speed.
    var isBusy: Bool { target > 1 || zoom > 1.001 }

    /// True while the loupe is on screen.
    var isShowing: Bool { window.isVisible }

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
        super.init()
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
    }

    /// Call on every overlay tick. `mouse` is in global screen coordinates.
    func update(held: Bool, mouse: CGPoint, screen: NSScreen) {
        let factor = CGFloat(Preferences.zoomFactor)
        if held {
            lastHeld = Date()
            ensureStream(for: screen)
        }
        let newTarget: CGFloat = held ? factor : 1
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
        } else if Preferences.zoomAnimated {
            let t = min(1, max(0, (CACurrentMediaTime() - animStart) / animDuration))
            let eased = CGFloat(1 - pow(1 - t, 3))
            zoom = animFrom + (target - animFrom) * eased
        } else {
            zoom = target
        }

        let visible = hasFrame && (held || zoom > 1.001)
        layout(mouse: mouse, screen: screen, visible: visible, factor: factor)

        if !held && zoom <= 1.001 && stream != nil && Date().timeIntervalSince(lastHeld) > Magnifier.keepStreamFor {
            stopStream()
        }
    }

    /// Close the loupe at once and stop capturing.
    func reset() {
        target = 1
        zoom = 1
        animFrom = 1
        setHidden(true)
        stopStream()
    }

    private func setHidden(_ hidden: Bool) {
        guard window.isVisible == hidden else {
            return
        }
        if hidden {
            window.orderOut(nil)
        } else {
            window.orderFrontRegardless()
        }
    }

    private func layout(mouse: CGPoint, screen: NSScreen, visible: Bool, factor: CGFloat) {
        guard visible else {
            setHidden(true)
            return
        }
        let frame = screen.frame
        let size = CGFloat(Preferences.loupeSize)
        let local = CGPoint(x: mouse.x - frame.minX, y: mouse.y - frame.minY)

        // Part of the screen shown in the loupe, in unit coordinates of the captured image
        // (origin at the bottom left, like the overlay view).
        let w = min(1, size / zoom / frame.width)
        let h = min(1, size / zoom / frame.height)
        let u = min(max(0, local.x / frame.width - w / 2), 1 - w)
        let v = min(max(0, local.y / frame.height - h / 2), 1 - h)

        // Fade the ring and shadow in with the zoom, so the loupe grows out of the screen.
        let progress = factor > 1 ? min(1, max(0, (zoom - 1) / (factor - 1))) : 1

        let ring = glass == nil ? 0 : Magnifier.ring
        window.setFrame(CGRect(x: mouse.x - size / 2, y: mouse.y - size / 2, width: size, height: size), display: false)
        if #available(macOS 26.0, *), let g = glass as? NSGlassEffectView {
            g.cornerRadius = size / 2
        }
        // Grow out of the screen: ring and shadow fade in with the zoom.
        window.alphaValue = glass == nil ? 1 : progress

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = CGRect(x: 0, y: 0, width: size, height: size).insetBy(dx: ring, dy: ring)
        let inner = layer.bounds.width
        layer.shadowPath = CGPath(ellipseIn: layer.bounds, transform: nil)
        layer.shadowOpacity = glass == nil ? Float(0.35 * progress) : 0
        content.frame = layer.bounds
        content.cornerRadius = inner / 2
        content.borderWidth = glass == nil ? 2 : 0
        content.borderColor = NSColor(white: 0, alpha: progress).cgColor
        content.contentsRect = CGRect(x: u, y: v, width: w, height: h)
        CATransaction.commit()
        setHidden(false)
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
