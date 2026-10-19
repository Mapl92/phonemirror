// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import MirrorCore

/// Gleicht die Zwischenablage zwischen Mac und iPhone ab – wie bei Apples iPhone-Mirroring:
/// - iPhone → Mac: Was auf dem iPhone kopiert wird, landet sofort in der Mac-Zwischenablage.
/// - Mac → iPhone: Nur solange PhoneMirror aktiv ist (bzw. beim Aktivieren), damit nicht jede Kopie
///   aus anderen Apps im Hintergrund aufs iPhone wandert.
@MainActor
final class ClipboardBridge {
    var isEnabled = true
    var onLocalChange: ((ClipboardContent) -> Void)?

    private let pasteboard = NSPasteboard.general
    private var lastSeenChangeCount: Int
    private var pollTask: Task<Void, Never>?
    /// iOS-Grenze von serve-web ist 32 MB; große Bilder gar nicht erst schicken.
    private let maxImageBytes = 20 * 1024 * 1024

    init() {
        lastSeenChangeCount = NSPasteboard.general.changeCount
        // Bewusst kein Timer mit `MainActor.assumeIsolated`: Ein Timer feuert auch in verschachtelten
        // Runloops mitten in einem MainActor-Job – dabei stürzte die Executor-Prüfung ab (EXC_BAD_ACCESS).
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

    /// Vom iPhone kopierter Inhalt → Mac.
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
        // Eigene Änderung nicht zurück aufs iPhone spiegeln.
        lastSeenChangeCount = pasteboard.changeCount
    }

    /// Markierung der Universellen Zwischenablage (Handoff): Der Inhalt kam schon von einem anderen Gerät.
    static let remoteClipboardType = NSPasteboard.PasteboardType("com.apple.is-remote-clipboard")

    private func poll() {
        guard isEnabled, NSApp.isActive, pasteboard.changeCount != lastSeenChangeCount else { return }
        lastSeenChangeCount = pasteboard.changeCount
        // Über Handoff angekommene Kopien (meist vom iPhone selbst) nicht zurückschicken – das würde
        // formatierte Kopien auf dem iPhone durch reinen Text ersetzen.
        if pasteboard.types?.contains(Self.remoteClipboardType) == true { return }
        if let content = currentContent() {
            onLocalChange?(content)
        }
    }

    /// Reiner Text aus HTML/RTF – damit auch Apps ohne Formatierung (Terminal, Textfelder) einfügen können.
    /// HTML nicht über NSAttributedString: Dessen HTML-Import läuft über WebKit und dreht eine
    /// verschachtelte Main-Runloop.
    static func plainText(_ data: Data, type: NSAttributedString.DocumentType) -> String? {
        if type == .html {
            // Zeilenumbrüche hinter Blockelementen erhalten, die stringValue sonst verschluckt.
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
