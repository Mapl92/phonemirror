// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CoreVideo
import MirrorCore

/// Zeigt den Videostream an und übersetzt Maus und Tastatur in Geräteeingaben.
@MainActor
final class MirrorView: NSView {
    var onInput: ((InputEvent) -> Void)?
    var screen = DeviceScreen.iPhone15 {
        didSet {
            needsLayout = true
            homeGesture = HomeIndicatorGestureRecognizer(screen: screen)
        }
    }

    /// Zeigt genau den Displaybereich mit abgerundeten Ecken. Der Bildinhalt kommt als IOSurface,
    /// `contentsRect` schneidet Padding (1184×2576 → 1179×2556) bzw. einen Resolution Collapse weg.
    private let videoLayer = CALayer()
    /// Zeigt die zurückgerechnete Touch-Position – macht Fehler im Koordinaten-Mapping sichtbar.
    private let touchIndicator = CAShapeLayer()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let agentBadge = NSTextField(labelWithString: "Agent steuert")
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
        TouchMapper(contentSize: screen.pointSize, viewBounds: bounds)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let videoRect = mapper.videoRect
        videoLayer.frame = videoRect
        videoLayer.cornerRadius = screen.cornerRadius * videoRect.width / screen.pointSize.width
        CATransaction.commit()
    }

    // MARK: - Video

    /// Zeigt ein dekodiertes Bild. `visible`: sichtbarer Anteil von links oben (siehe `ContentRectDetector`).
    func display(_ pixelBuffer: CVPixelBuffer, visible: CGSize) {
        guard let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.contents = surface
        // IOSurface-Inhalte haben den Ursprung oben links – der sichtbare Teil beginnt bei (0, 0).
        videoLayer.contentsRect = CGRect(x: 0, y: 0, width: visible.width, height: visible.height)
        CATransaction.commit()
        if !statusLabel.isHidden { statusLabel.isHidden = true }
    }

    func clearVideo() {
        videoLayer.contents = nil
    }

    /// Zeigt für 3 s „Agent steuert“ und ggf. die vom Agent berührte Stelle.
    func showAgentActivity(at point: TouchPoint?) {
        agentBadge.stringValue = "  Agent steuert  "
        agentBadge.isHidden = false
        if let point { updateIndicator(point) }
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

    // MARK: - Maus → Touch

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let point = mapper.devicePoint(for: location(of: event)) else { return }
        // Am Home-Balken beginnend: als Home/App-Umschalter auswerten statt als Touch senden.
        if homeGesture.began(at: point, time: event.timestamp) {
            updateIndicator(point)
            return
        }
        activeTouch = true
        // Nahe am oberen/linken Rand beginnende Touches auf die Kante setzen (Mitteilungen, Zurück).
        sendTouch(.began, edgeSnapping.snap(point, on: screen))
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

    /// Rechtsklick = Home (wie bei pymobiledevice3 serve-web).
    override func rightMouseDown(with event: NSEvent) {
        onInput?(.button(.home, isDown: true))
        onInput?(.button(.home, isDown: false))
    }

    /// Trackpad/Mausrad → Wischgeste. Momentum-Phasen werden ignoriert: Nach dem Loslassen
    /// erzeugt iOS seinen eigenen Schwung, sonst würde doppelt gescrollt.
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
        // scrollingDelta entspricht beim natürlichen Scrollen der Fingerbewegung.
        let factor = event.hasPreciseScrollingDeltas ? 1.0 : 10.0
        let dx = event.scrollingDeltaX * factor
        let dy = event.scrollingDeltaY * factor
        guard dx != 0 || dy != 0 else { return }
        onInput?(.scroll(dx: dx, dy: dy, at: lastPointer))
    }

    private func sendTouch(_ phase: TouchPhase, _ point: TouchPoint) {
        lastPointer = point
        onInput?(.touch(phase, point))
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

    // MARK: - Tastatur

    override func keyDown(with event: NSEvent) {
        // Gehaltene Tasten wiederholt iOS selbst – Auto-Repeat des Mac nicht weiterreichen.
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
