// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import MirrorCore

/// Syncs the clipboard between Mac and iPhone – as in Apple's iPhone Mirroring:
/// - iPhone → Mac: whatever is copied on the iPhone lands in the Mac clipboard immediately.
/// - Mac → iPhone: only while PhoneMirror is active (or on activation), so that not every copy
///   from other apps in the background travels to the iPhone.
@MainActor
final class ClipboardBridge {
    var isEnabled = true
    var onLocalChange: ((ClipboardContent) -> Void)?

    private let pasteboard = NSPasteboard.general
    private var lastSeenChangeCount: Int
    private var pollTask: Task<Void, Never>?
    /// serve-web's iOS limit is 32 MB; don't even send large images.
    private let maxImageBytes = 20 * 1024 * 1024

    init() {
        lastSeenChangeCount = NSPasteboard.general.changeCount
        // Deliberately no timer with `MainActor.assumeIsolated`: a timer also fires in nested
        // run loops in the middle of a MainActor job – the executor check crashed there (EXC_BAD_ACCESS).
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self?.poll()
            }
        }
    }

    func invalidate() {
        pollTask?.cancel()
        pollTask = nil
    }

    func ignoreCurrentContent() {
        lastSeenChangeCount = pasteboard.changeCount
    }

    /// Content copied on the iPhone → Mac.
    func applyRemote(_ content: ClipboardContent) {
        guard isEnabled else { return }
        pasteboard.clearContents()
        switch content {
        case .text(let text):
            pasteboard.setString(text, forType: .string)
        case .png(let png):
            pasteboard.setData(png, forType: .png)
        case .html(let html):
            pasteboard.setData(html, forType: .html)
            if let text = Self.plainText(html, type: .html) { pasteboard.setString(text, forType: .string) }
        case .rtf(let rtf):
            pasteboard.setData(rtf, forType: .rtf)
            if let text = Self.plainText(rtf, type: .rtf) { pasteboard.setString(text, forType: .string) }
        }
        // Don't mirror our own change back to the iPhone.
        lastSeenChangeCount = pasteboard.changeCount
    }

    /// Marker of the Universal Clipboard (Handoff): the content already came from another device.
    static let remoteClipboardType = NSPasteboard.PasteboardType("com.apple.is-remote-clipboard")

    private func poll() {
        guard isEnabled, NSApp.isActive, pasteboard.changeCount != lastSeenChangeCount else { return }
        lastSeenChangeCount = pasteboard.changeCount
        // Don't send back copies that arrived via Handoff (usually from the iPhone itself) – that would
        // replace formatted copies on the iPhone with plain text.
        if pasteboard.types?.contains(Self.remoteClipboardType) == true { return }
        if let content = currentContent() {
            onLocalChange?(content)
        }
    }

    /// Plain text from HTML/RTF – so that apps without formatting (Terminal, text fields) can paste too.
    /// HTML not via NSAttributedString: its HTML import goes through WebKit and spins a
    /// nested main run loop.
    static func plainText(_ data: Data, type: NSAttributedString.DocumentType) -> String? {
        if type == .html {
            // Keep line breaks after block elements, which stringValue would otherwise swallow.
            guard let html = String(data: data, encoding: .utf8) else { return nil }
            let marked = html.replacingOccurrences(
                of: "(<br\\s*/?>|</(p|div|li|tr|h[1-6]|blockquote|pre)>)", with: "$1\n",
                options: [.regularExpression, .caseInsensitive])
            guard let document = try? XMLDocument(xmlString: marked, options: [.documentTidyHTML]) else { return nil }
            for node in (try? document.nodes(forXPath: "//script|//style|//head")) ?? [] {
                node.detach()
            }
            return document.rootElement()?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: type, .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        return (try? NSAttributedString(data: data, options: options, documentAttributes: nil))?.string
    }

    private func currentContent() -> ClipboardContent? {
        if let text = pasteboard.string(forType: .string) {
            return .text(text)
        }
        if let png = pasteboard.data(forType: .png), png.count <= maxImageBytes {
            return .png(png)
        }
        if let tiff = pasteboard.data(forType: .tiff),
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
           png.count <= maxImageBytes {
            return .png(png)
        }
        return nil
    }
}
