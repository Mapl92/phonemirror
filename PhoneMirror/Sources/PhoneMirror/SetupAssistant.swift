// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import MirrorNative

/// Pairs the iPhone with this Mac through `remotepairingd` and reveals the Developer Mode switch via AMFI –
/// the two steps that otherwise need Xcode. The mirror connection pauses while the assistant is open.
@MainActor
final class SetupAssistantController: NSWindowController, NSWindowDelegate {
    private let pairStatus = NSTextField(wrappingLabelWithString: "")
    private let developerStatus = NSTextField(wrappingLabelWithString: "")
    private let pairButton = NSButton(title: "Pair", target: nil, action: nil)
    private let revealButton = NSButton(title: "Show Developer Mode Switch", target: nil, action: nil)
    private var busy = false {
        didSet { refreshButtons() }
    }
    private var isPaired = false
    private var developerModeOn: Bool?
    /// Called when the window closes; the owner resumes the mirror connection.
    var onClose: (() -> Void)?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Set Up iPhone"
        super.init(window: window)
        window.delegate = self
        window.contentView = makeContent()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        Task { await refresh() }
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    // MARK: Layout

    private func makeContent() -> NSView {
        let title = NSTextField(labelWithString: "Set up your iPhone for PhoneMirror")
        title.font = .boldSystemFont(ofSize: 15)

        pairButton.target = self
        pairButton.action = #selector(pair)
        revealButton.target = self
        revealButton.action = #selector(revealDeveloperMode)
        let done = NSButton(title: "Done", target: self, action: #selector(finish))
        done.keyEquivalent = "\r"

        let stack = NSStackView(views: [
            title,
            section("1. Pair with this Mac",
                    "Connect the iPhone with a USB cable and unlock it. Click Pair, then tap “Trust” on the iPhone and enter its passcode. After that, Wi-Fi is enough.",
                    button: pairButton, status: pairStatus),
            section("2. Turn on Developer Mode",
                    "PhoneMirror shows the switch in Settings › Privacy & Security › Developer Mode. Turn it on, let the iPhone restart, then confirm “Turn On” and enter the passcode.",
                    button: revealButton, status: developerStatus),
            done,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.setCustomSpacing(24, after: stack.views[2])
        done.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func section(_ heading: String, _ text: String, button: NSButton, status: NSTextField) -> NSView {
        let headingLabel = NSTextField(labelWithString: heading)
        headingLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        let body = NSTextField(wrappingLabelWithString: text)
        body.preferredMaxLayoutWidth = 440
        status.preferredMaxLayoutWidth = 440
        status.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [headingLabel, body, button, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        return stack
    }

    private func refreshButtons() {
        pairButton.isEnabled = !busy && !isPaired
        revealButton.isEnabled = !busy && isPaired && developerModeOn != true
    }

    // MARK: Steps

    /// Reads the current state: paired? Developer Mode on?
    private func refresh() async {
        busy = true
        defer { busy = false }
        pairStatus.stringValue = "Looking for the iPhone…"
        let summary = await Task.detached { () -> RemotePairingTunnel.DeviceSummary? in
            let tunnel = RemotePairingTunnel()
            defer { tunnel.close() }
            try? tunnel.find()
            return tunnel.device
        }.value
        guard let summary else {
            isPaired = false
            pairStatus.stringValue = "No iPhone found. Connect it by USB and unlock it."
            developerStatus.stringValue = ""
            return
        }
        isPaired = summary.isPaired
        pairStatus.stringValue = summary.isPaired ? "✓ “\(summary.name)” is paired with this Mac." : "“\(summary.name)” is not paired yet."
        guard summary.isPaired else {
            developerStatus.stringValue = "Pair first."
            return
        }
        developerStatus.stringValue = "Checking Developer Mode…"
        developerModeOn = await Self.developerModeStatus()
        switch developerModeOn {
        case true?: developerStatus.stringValue = "✓ Developer Mode is on."
        case false?: developerStatus.stringValue = "Developer Mode is off."
        case nil: developerStatus.stringValue = "Could not read Developer Mode (is the iPhone unlocked and reachable?)."
        }
    }

    private static func developerModeStatus() async -> Bool? {
        guard let rsd = try? await RemoteServiceDiscovery.connect() else { return nil }
        defer { rsd.close() }
        return try? await DeveloperMode.isEnabled(rsd: rsd)
    }

    @objc private func pair() {
        busy = true
        pairStatus.stringValue = "Tap “Trust” on the iPhone and enter its passcode…"
        Task {
            let result = await Task.detached { () -> Error? in
                let tunnel = RemotePairingTunnel()
                defer { tunnel.close() }
                do { try tunnel.pair() } catch { return error }
                return nil
            }.value
            busy = false
            if let result {
                pairStatus.stringValue = "Pairing failed: \(result.localizedDescription)"
            } else {
                await refresh()
            }
        }
    }

    @objc private func revealDeveloperMode() {
        busy = true
        developerStatus.stringValue = "Showing the switch…"
        Task {
            do {
                let rsd = try await RemoteServiceDiscovery.connect()
                defer { rsd.close() }
                try await DeveloperMode.revealSetting(rsd: rsd)
                developerStatus.stringValue = "Now on the iPhone: Settings › Privacy & Security › Developer Mode → on. After the restart, confirm “Turn On”, then click Done."
            } catch {
                developerStatus.stringValue = "Could not show the switch: \(error.localizedDescription)"
            }
            busy = false
        }
    }

    @objc private func finish() {
        window?.close()
    }
}
