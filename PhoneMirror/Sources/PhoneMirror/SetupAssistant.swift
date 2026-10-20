// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import MirrorNative
import UniformTypeIdentifiers

/// Pairs the iPhone with this Mac through `remotepairingd` and reveals the Developer Mode switch via AMFI –
/// the two steps that otherwise need Xcode. The mirror connection pauses while the assistant is open.
@MainActor
final class SetupAssistantController: NSWindowController, NSWindowDelegate {
    private let pairStatus = NSTextField(wrappingLabelWithString: "")
    private let developerStatus = NSTextField(wrappingLabelWithString: "")
    private let pairButton = NSButton(title: "Pair", target: nil, action: nil)
    private let revealButton = NSButton(title: "Show Developer Mode Switch", target: nil, action: nil)
    private let imageStatus = NSTextField(wrappingLabelWithString: "")
    private let importButton = NSButton(title: "Choose File…", target: nil, action: nil)
    private let downloadButton = NSButton(title: "Open Download Page", target: nil, action: nil)
    private let fetchButton = NSButton(title: "Download from Apple…", target: nil, action: nil)
    private var signIn: AppleDownloadSignInController?
    /// The Apple Developer session of this app run (memory only), so a retry needs no new sign-in.
    private static var session: (result: AppleDownloadSignInController.Result, time: Date)?
    private var busy = false {
        didSet { refreshButtons() }
    }
    private var isPaired = false
    /// The iPhone the assistant works on: the chosen one, else an unpaired one that is connected, else the first.
    private var target: RemotePairingTunnel.DeviceSummary?
    private var developerModeOn: Bool?
    /// Called when the window closes; the owner resumes the mirror connection.
    var onClose: (() -> Void)?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
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
        importButton.target = self
        importButton.action = #selector(chooseImage)
        downloadButton.target = self
        downloadButton.action = #selector(openDownloadPage)
        fetchButton.target = self
        fetchButton.action = #selector(fetchFromApple)
        let imageButtons = NSStackView(views: [fetchButton, importButton, downloadButton])
        imageButtons.spacing = 8
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
            section("3. Developer Disk Image",
                    "PhoneMirror needs Apple's Developer Disk Image, which ships with Xcode. “Download from Apple…” signs you in to Apple Developer and fetches just that part – Xcode is not installed. Or choose an Xcode download (.xip), an Xcode.app, iOS_DDI.dmg or an iOS_DDI folder.",
                    button: imageButtons, status: imageStatus),
            done,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.setCustomSpacing(24, after: stack.views[3])
        done.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func section(_ heading: String, _ text: String, button: NSView, status: NSTextField) -> NSView {
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
        importButton.isEnabled = !busy
        fetchButton.isEnabled = !busy
    }

    private func refreshImageStatus() {
        if let image = DeveloperDiskImageStore.installed() {
            imageStatus.stringValue = "✓ Developer Disk Image \(image.build) is available."
        } else if let xcode = DeveloperDiskImageStore.xcodeApplications().first {
            imageStatus.stringValue = "Will be taken from \(xcode.lastPathComponent) automatically."
        } else {
            imageStatus.stringValue = "Not found yet."
        }
    }

    // MARK: Steps

    /// Reads the current state: paired? Developer Mode on?
    private func refresh() async {
        busy = true
        defer { busy = false }
        refreshImageStatus()
        pairStatus.stringValue = "Looking for the iPhone…"
        let devices = await Task.detached { RemotePairingTunnel.listDevices() }.value
        let selected = AppSettings.shared.selectedDevice
        let summary = devices.first { $0.udid == selected }
            ?? devices.first { !$0.isPaired && $0.isConnected }
            ?? devices.first { $0.isPaired }
            ?? devices.first
        target = summary
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
        developerModeOn = await Self.developerModeStatus(udid: summary.udid)
        switch developerModeOn {
        case true?: developerStatus.stringValue = "✓ Developer Mode is on."
        case false?: developerStatus.stringValue = "Developer Mode is off."
        case nil: developerStatus.stringValue = "Could not read Developer Mode (is the iPhone unlocked and reachable?)."
        }
    }

    /// Right after the mirror connection pauses the iPhone is briefly unreachable – retry a few times.
    private static func developerModeStatus(udid: String) async -> Bool? {
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(2)) }
            guard let rsd = try? await RemoteServiceDiscovery.connect(udid: udid) else { continue }
            defer { rsd.close() }
            if let enabled = try? await DeveloperMode.isEnabled(rsd: rsd) { return enabled }
        }
        return nil
    }

    @objc private func pair() {
        busy = true
        pairStatus.stringValue = "Tap “Trust” on the iPhone and enter its passcode…"
        let udid = target?.udid
        Task {
            let result = await Task.detached { () -> Error? in
                let tunnel = RemotePairingTunnel()
                defer { tunnel.close() }
                do { try tunnel.pair(udid: udid) } catch { return error }
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
                let rsd = try await RemoteServiceDiscovery.connect(udid: target?.udid)
                defer { rsd.close() }
                try await DeveloperMode.revealSetting(rsd: rsd)
                developerStatus.stringValue = "Now on the iPhone: Settings › Privacy & Security › Developer Mode → on. After the restart, confirm “Turn On”, then click Done."
            } catch {
                developerStatus.stringValue = "Could not show the switch: \(error.localizedDescription)"
            }
            busy = false
        }
    }

    /// Sign in to Apple Developer, then read only the needed parts of the newest Xcode `.xip`.
    @objc private func fetchFromApple() {
        busy = true
        if let session = Self.session, Date().timeIntervalSince(session.time) < 20 * 60 {
            download(session.result)
            return
        }
        imageStatus.stringValue = "Sign in with your Apple Account in the new window…"
        let controller = AppleDownloadSignInController { [weak self] result in
            guard let self else { return }
            self.signIn = nil
            guard let result else {
                self.imageStatus.stringValue = "Sign-in cancelled."
                self.busy = false
                return
            }
            Self.session = (result, Date())
            self.download(result)
        }
        signIn = controller
        controller.start()
    }

    private func download(_ result: AppleDownloadSignInController.Result) {
        imageStatus.stringValue = "Reading \(result.xcodeName) from Apple…"
        let label = imageStatus
        Task {
            do {
                let (info, report) = try await DeveloperDiskImageStore.importFromApple(xipURL: result.xipURL, cookies: result.cookies) { message in
                    Task { @MainActor in label.stringValue = message }
                }
                imageStatus.stringValue = "✓ Developer Disk Image \(info.build) from \(result.xcodeName). \(report)"
            } catch {
                imageStatus.stringValue = error.localizedDescription
            }
            busy = false
        }
    }

    @objc private func openDownloadPage() {
        NSWorkspace.shared.open(URL(string: "https://developer.apple.com/download/all/?q=Xcode")!)
    }

    @objc private func chooseImage() {
        let panel = NSOpenPanel()
        panel.message = "Choose an Xcode download (.xip), Xcode.app, iOS_DDI.dmg or an iOS_DDI folder."
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["xip", "app", "pkg", "dmg"].compactMap { UTType(filenameExtension: $0) } + [.folder]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true
        imageStatus.stringValue = "Importing…"
        let label = imageStatus
        Task {
            do {
                let info = try await DeveloperDiskImageStore.importDDI(from: url) { message in
                    Task { @MainActor in label.stringValue = message }
                }
                imageStatus.stringValue = "✓ Developer Disk Image \(info.build) imported."
            } catch {
                imageStatus.stringValue = error.localizedDescription
            }
            busy = false
        }
    }

    @objc private func finish() {
        window?.close()
    }
}
