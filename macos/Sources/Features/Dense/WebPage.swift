import AppKit
import SwiftUI
import WebKit

/// What a web tab shows (a Surface of kind web): one page, or with `navigation` a small
/// browser. The tab keeps its page while it is out of view, as a terminal tab keeps its
/// terminal, so switching back is instant.
///
/// Without `navigation`, the tab shows only its page: a link clicked there opens in the
/// default browser instead. The page's own scripts may still load other pages.
final class WebPage: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let view = WKWebView()

    /// What the tab's Surface asks for, as last loaded.
    @Published private(set) var spec: Surface.Web

    @Published private(set) var url: URL?
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var loading = false

    private var observations: [NSKeyValueObservation] = []

    init(_ spec: Surface.Web) {
        self.spec = spec
        super.init()
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = spec.navigation == true
        observations = [
            view.observe(\.url) { [weak self] view, _ in self?.url = view.url },
            view.observe(\.canGoBack) { [weak self] view, _ in self?.canGoBack = view.canGoBack },
            view.observe(\.canGoForward) { [weak self] view, _ in self?.canGoForward = view.canGoForward },
            view.observe(\.isLoading) { [weak self] view, _ in self?.loading = view.isLoading },
        ]
        load(spec)
    }

    /// Loads the page a Surface asks for: its html, else its url. A file may read the files
    /// next to it, for its pictures and scripts.
    func load(_ spec: Surface.Web) {
        self.spec = spec
        view.allowsBackForwardNavigationGestures = spec.navigation == true
        if let html = spec.html {
            view.loadHTMLString(html, baseURL: nil)
        } else if let url = spec.url.flatMap(URL.init(string:)) {
            open(url)
        }
    }

    private func open(_ url: URL) {
        if url.isFileURL {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            view.load(URLRequest(url: url))
        }
    }

    /// Goes to what was typed in the address field.
    func go(_ address: String) {
        guard let url = Self.url(address) else { return NSSound.beep() }
        open(url)
    }

    /// The URL a typed address means: a path (/ or ~) is a file, and without a scheme it is
    /// taken as https.
    static func url(_ address: String) -> URL? {
        let address = address.trimmingCharacters(in: .whitespaces)
        if address.hasPrefix("/") || address.hasPrefix("~") {
            return URL(fileURLWithPath: NSString(string: address).expandingTildeInPath)
        }
        return address.isEmpty ? nil : URL(string: address.contains("://") ? address : "https://" + address)
    }

    /// Moves the focus to the page, now or once it is in a window.
    func focus() {
        if let window = view.window {
            window.makeFirstResponder(view)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let view = self?.view else { return }
                view.window?.makeFirstResponder(view)
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // A link clicked to another page, without navigation, opens in the default browser.
        // A link within the page (#section) stays.
        guard spec.navigation != true, action.navigationType == .linkActivated,
              action.targetFrame?.isMainFrame != false,
              let url = action.request.url, !Self.samePage(url, webView.url) else { return decisionHandler(.allow) }
        Self.openOutside(url)
        decisionHandler(.cancel)
    }

    /// A link that asks for a new window (target="_blank", window.open): with navigation it
    /// opens in the tab, as dense has no windows to give it; without, in the default browser
    /// if it was clicked.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if spec.navigation == true {
            webView.load(action.request)
        } else if action.navigationType == .linkActivated, let url = action.request.url {
            Self.openOutside(url)
        }
        return nil
    }

    /// Whether two URLs are the same page, maybe at different #sections.
    static func samePage(_ a: URL, _ b: URL?) -> Bool {
        guard let b, var x = URLComponents(url: a, resolvingAgainstBaseURL: true),
              var y = URLComponents(url: b, resolvingAgainstBaseURL: true) else { return false }
        x.fragment = nil
        y.fragment = nil
        return x == y
    }

    /// Opens a web or mail link in the default app. Other schemes, which could start any app,
    /// are not opened: the page may be anyone's.
    private static func openOutside(_ url: URL) {
        guard ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return NSSound.beep() }
        NSWorkspace.shared.open(url)
    }
}

/// A web tab in the window: its page, under a toolbar if it is a browser.
struct WebPane: View {
    @ObservedObject var page: WebPage
    /// The address field's text, which follows the page until it is typed into.
    @State private var address = ""

    var body: some View {
        VStack(spacing: 0) {
            if page.spec.navigation == true {
                HStack(spacing: 4) {
                    button("chevron.left", "Back", enabled: page.canGoBack) { page.view.goBack() }
                    button("chevron.right", "Forward", enabled: page.canGoForward) { page.view.goForward() }
                    if page.loading {
                        button("xmark", "Stop") { page.view.stopLoading() }
                    } else {
                        button("arrow.clockwise", "Reload") { page.view.reload() }
                    }
                    TextField("Address", text: $address)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { page.go(address) }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .onAppear { address = page.url?.absoluteString ?? "" }
                .onChange(of: page.url) { address = $0?.absoluteString ?? "" }
            }
            WebViewHost(view: page.view)
        }
    }

    private func button(_ symbol: String, _ help: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(!enabled)
        .help(help)
    }
}

/// Puts a page's web view, made once by its `WebPage`, in the SwiftUI layout. It goes in a
/// box of its own, as SwiftUI may make the next box before it drops the last one.
private struct WebViewHost: NSViewRepresentable {
    let view: WKWebView

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ box: NSView, context: Context) {
        guard view.superview !== box else { return }
        view.removeFromSuperview()
        view.frame = box.bounds
        view.autoresizingMask = [.width, .height]
        box.addSubview(view)
    }
}
