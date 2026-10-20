// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import WebKit

/// Apple's developer download page in a web view: the user signs in there (Apple Account, two-factor
/// authentication). Afterwards PhoneMirror takes the session cookies – kept in memory only, the web view uses a
/// non-persistent store – and the link to the newest Xcode release, to read parts of the `.xip` itself.
@MainActor
final class AppleDownloadSignInController: NSWindowController, WKNavigationDelegate, NSWindowDelegate {
    struct Result {
        var xipURL: URL
        var xcodeName: String
        var cookies: [HTTPCookie]
    }

    private let webView: WKWebView
    private var completion: ((Result?) -> Void)?
    private var polling: Task<Void, Never>?
    static let downloadsPage = URL(string: "https://developer.apple.com/download/all/?q=Xcode")!

    init(completion: @escaping (Result?) -> Void) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 960, height: 720), configuration: configuration)
        self.completion = completion
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Sign in to Apple Developer – PhoneMirror"
        window.contentView = webView
        super.init(window: window)
        window.delegate = self
        webView.navigationDelegate = self
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func start() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        webView.load(URLRequest(url: Self.downloadsPage))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView.url?.host == "developer.apple.com", webView.url?.path.hasPrefix("/download") == true else { return }
        polling?.cancel()
        polling = Task { await waitForDownloads() }
    }

    /// The list loads via JavaScript after sign-in; the download cookie appears with it.
    private func waitForDownloads() async {
        for _ in 0..<60 {
            if Task.isCancelled { return }
            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                .filter { $0.domain.hasSuffix("apple.com") }
            if cookies.contains(where: { $0.name == "ADCDownloadAuth" }), let (url, name) = await newestXcode() {
                finish(Result(xipURL: url, xcodeName: name, cookies: cookies))
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// Newest release (no beta/RC) among the page's "Xcode N.N.xip" links.
    private func newestXcode() async -> (URL, String)? {
        let script = """
        Array.from(document.querySelectorAll('a'))
          .map(a => [a.textContent.trim(), a.href])
          .filter(([text, href]) => /^Xcode \\d+(\\.\\d+)*\\.xip$/.test(text) && href.startsWith('https://download.developer.apple.com/'))
        """
        guard let pairs = try? await webView.evaluateJavaScript(script) as? [[String]], !pairs.isEmpty else { return nil }
        func version(_ name: String) -> [Int] {
            name.replacingOccurrences(of: "Xcode ", with: "").replacingOccurrences(of: ".xip", with: "")
                .split(separator: ".").compactMap { Int($0) }
        }
        let best = pairs.max { a, b in version(a[0]).lexicographicallyPrecedes(version(b[0])) }
        guard let best, let url = URL(string: best[1]) else { return nil }
        return (url, best[0].replacingOccurrences(of: ".xip", with: ""))
    }

    private func finish(_ result: Result?) {
        polling?.cancel()
        let completion = self.completion
        self.completion = nil
        completion?(result)
        close()
    }

    func windowWillClose(_ notification: Notification) {
        polling?.cancel()
        let completion = self.completion
        self.completion = nil
        completion?(nil)
    }
}
