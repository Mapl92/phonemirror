// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CoreVideo
import MirrorCore

/// Shows the video stream and translates mouse and keyboard into device input.
@MainActor
final class MirrorView: NSView {
    var onInput: ((InputEvent) -> Void)?
    /// Native (portrait) geometry of the device display.
    var screen = DeviceScreen.iPhone15 {
        didSet { geometryChanged() }
    }

    /// How the content is turned: the video stays native, the view rotates it upright and maps input back.
    var orientation = DeviceOrientation.portrait {
        didSet { geometryChanged() }
    }

    /// The screen as the viewer sees it – all mouse handling works in this space.
    var displayedScreen: DeviceScreen { orientation.displayed(screen) }

    private func geometryChanged() {
        needsLayout = true
        homeGesture = HomeIndicatorGestureRecognizer(screen: displayedScreen)
    }

    /// Shows exactly the display area with rounded corners. The image content arrives as an IOSurface;
    /// `contentsRect` crops away padding (1184×2576 → 1179×2556) or a resolution collapse.
    private let videoLayer = CALayer()
    /// Shows the back-computed touch position – makes errors in the coordinate mapping visible.
    private let touchIndicator = CAShapeLayer()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let agentBadge = NSTextField(labelWithString: "Agent in control")
    private var agentBadgeHideTask: Task<Void, Never>?
    private var activeTouch = false
    private let edgeSnapping = EdgeSnapping()
    private var homeGesture = HomeIndicatorGestureRecognizer(screen: .iPhone15)
    private var lastPointer = TouchPoint(x: TouchPoint.maxValue / 2, y: TouchPoint.maxValue / 2)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        videoLayer.masksToBounds = true
        videoLayer.backgroundColor = NSColor.black.cgColor
        videoLayer.contentsGravity = .resize
        videoLayer.minificationFilter = .trilinear
        layer?.addSublayer(videoLayer)

        touchIndicator.fillColor = NSColor.white.withAlphaComponent(0.35).cgColor
        touchIndicator.strokeColor = NSColor.white.withAlphaComponent(0.8).cgColor
        touchIndicator.lineWidth = 1.5
        touchIndicator.isHidden = true
        layer?.addSublayer(touchIndicator)

        agentBadge.font = .systemFont(ofSize: 11, weight: .semibold)
        agentBadge.textColor = .white
        agentBadge.backgroundColor = NSColor.systemPurple.withAlphaComponent(0.85)
        agentBadge.drawsBackground = true
        agentBadge.alignment = .center
        agentBadge.isHidden = true
        agentBadge.wantsLayer = true
        agentBadge.layer?.cornerRadius = 4
        agentBadge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(agentBadge)
        NSLayoutConstraint.activate([
            agentBadge.centerXAnchor.constraint(equalTo: centerXAnchor),
            agentBadge.topAnchor.constraint(equalTo: topAnchor, constant: 34),
        ])

        statusLabel.alignment = .center
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var mapper: TouchMapper {
        TouchMapper(contentSize: displayedScreen.pointSize, viewBounds: bounds)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let videoRect = mapper.videoRect
        // The layer keeps the native (portrait) shape and is turned around its center.
        let nativeSize = orientation.isLandscape ? CGSize(width: videoRect.height, height: videoRect.width) : videoRect.size
        videoLayer.setAffineTransform(.identity)
        videoLayer.bounds = CGRect(origin: .zero, size: nativeSize)
        videoLayer.position = CGPoint(x: videoRect.midX, y: videoRect.midY)
        videoLayer.setAffineTransform(CGAffineTransform(rotationAngle: Self.rotationSign * CGFloat(orientation.quarterTurns) * .pi / 2))
        videoLayer.cornerRadius = screen.cornerRadius * nativeSize.width / screen.pointSize.width
        CATransaction.commit()
    }

    /// Direction of a positive rotation angle in this (flipped) view: +1 turns clockwise on screen.
    static let rotationSign: CGFloat = 1

    // MARK: - Video

    /// Shows a decoded image. `visible`: visible fraction from the top left (see `ContentRectDetector`).
    func display(_ pixelBuffer: CVPixelBuffer, visible: CGSize) {
        guard let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.contents = surface
        // IOSurface contents have their origin at the top left – the visible part starts at (0, 0).
        videoLayer.contentsRect = CGRect(x: 0, y: 0, width: visible.width, height: visible.height)
        CATransaction.commit()
        if !statusLabel.isHidden { statusLabel.isHidden = true }
    }

    func clearVideo() {
        videoLayer.contents = nil
    }

    /// Shows “Agent in control” for 3 s and, if given, the spot the agent touched.
    func showAgentActivity(at point: TouchPoint?) {
        agentBadge.stringValue = "  Agent in control  "
        agentBadge.isHidden = false
        if let point { updateIndicator(orientation.displayed(point)) }
        agentBadgeHideTask?.cancel()
        agentBadgeHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(point == nil ? 3 : 0.4))
            guard !Task.isCancelled else { return }
            self?.updateIndicator(nil)
            try? await Task.sleep(for: .seconds(point == nil ? 0 : 2.6))
            guard !Task.isCancelled else { return }
            self?.agentBadge.isHidden = true
        }
    }

    func showStatus(_ text: String) {
        statusLabel.stringValue = text
        statusLabel.isHidden = false
    }

    // MARK: - Mouse → touch

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let point = mapper.devicePoint(for: location(of: event)) else { return }
        // Starting at the home bar: interpret as Home/App Switcher instead of sending a touch.
        if homeGesture.began(at: point, time: event.timestamp) {
            updateIndicator(point)
            return
        }
        activeTouch = true
        // Snap touches that start near the top/left edge onto the edge (Notifications, Back).
        sendTouch(.began, edgeSnapping.snap(point, on: displayedScreen))
    }

    override func mouseDragged(with event: NSEvent) {
        let point = mapper.clampedDevicePoint(for: location(of: event))
        if homeGesture.isActive {
            homeGesture.moved(to: point, time: event.timestamp)
            updateIndicator(point)
            return
        }
        guard activeTouch else { return }
        sendTouch(.moved, point)
    }

    override func mouseUp(with event: NSEvent) {
        let point = mapper.clampedDevicePoint(for: location(of: event))
        if homeGesture.isActive {
            updateIndicator(nil)
            switch homeGesture.ended(at: point, time: event.timestamp) {
            case .home:
                onInput?(.button(.home, isDown: true))
                onInput?(.button(.home, isDown: false))
            case .appSwitcher:
                onInput?(.gesture(.appSwitcher))
            case nil:
                break
            }
            return
        }
        guard activeTouch else { return }
        activeTouch = false
        sendTouch(.ended, point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        if let point = mapper.devicePoint(for: location(of: event)) { lastPointer = point }
    }

    /// Right click = Home (as in pymobiledevice3 serve-web).
    override func rightMouseDown(with event: NSEvent) {
        onInput?(.button(.home, isDown: true))
        onInput?(.button(.home, isDown: false))
    }

    /// Trackpad/mouse wheel → swipe gesture. Momentum phases are ignored: after release
    /// iOS generates its own momentum, otherwise it would scroll twice.
    override func scrollWheel(with event: NSEvent) {
        guard event.momentumPhase.isEmpty else { return }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            onInput?(.scrollEnded)
            return
        }
        if event.phase.contains(.began) || event.phase.isEmpty,
           let point = mapper.devicePoint(for: location(of: event)) {
            lastPointer = point
        }
        // With natural scrolling, scrollingDelta matches the finger movement.
        let factor = event.hasPreciseScrollingDeltas ? 1.0 : 10.0
        let dx = event.scrollingDeltaX * factor
        let dy = event.scrollingDeltaY * factor
        guard dx != 0 || dy != 0 else { return }
        let native = orientation.native(dx: dx, dy: dy)
        onInput?(.scroll(dx: native.dx, dy: native.dy, at: orientation.native(lastPointer)))
    }

    private func sendTouch(_ phase: TouchPhase, _ point: TouchPoint) {
        lastPointer = point
        onInput?(.touch(phase, orientation.native(point)))
        updateIndicator(phase == .ended ? nil : point)
    }

    private func location(of event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    private func updateIndicator(_ point: TouchPoint?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let point {
            let center = mapper.viewPoint(for: point)
            let radius = 14.0
            touchIndicator.path = CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2), transform: nil)
            touchIndicator.isHidden = false
        } else {
            touchIndicator.isHidden = true
        }
        CATransaction.commit()
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        // iOS repeats held keys itself – don't pass on the Mac's auto-repeat.
        guard !event.isARepeat, let usage = KeyMapping.hidUsage(forMacKeyCode: event.keyCode) else { return }
        onInput?(.key(usage: usage, isDown: true))
    }

    override func keyUp(with event: NSEvent) {
        guard let usage = KeyMapping.hidUsage(forMacKeyCode: event.keyCode) else { return }
        onInput?(.key(usage: usage, isDown: false))
    }

    override func flagsChanged(with event: NSEvent) {
        guard KeyMapping.isModifier(event.keyCode), let usage = KeyMapping.hidUsage(forMacKeyCode: event.keyCode) else { return }
        let isDown: Bool = switch event.keyCode {
        case 0x37, 0x36: event.modifierFlags.contains(.command)
        case 0x38, 0x3C: event.modifierFlags.contains(.shift)
        case 0x3A, 0x3D: event.modifierFlags.contains(.option)
        case 0x3B, 0x3E: event.modifierFlags.contains(.control)
        default: event.modifierFlags.contains(.capsLock)
        }
        onInput?(.key(usage: usage, isDown: isDown))
    }
}
