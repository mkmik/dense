import AppKit
import SwiftUI
import WebKit

/// What a tab with no terminal shows, in the terminal area's place: a web page, or an
/// Extension's surface (`UIPage`).
protocol TabPage: AnyObject {
    /// The view to put in the window; the tab comes to the front when it takes the focus.
    var root: NSView { get }
}

extension TabPage {
    /// Moves the focus to the view, now or once it is in a window.
    func focus() {
        if let window = root.window {
            window.makeFirstResponder(root)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let root = self?.root else { return }
                root.window?.makeFirstResponder(root)
            }
        }
    }
}

/// What a web tab shows (a Surface of kind web): one page, or with `navigation` a small
/// browser. The tab keeps its page while it is out of view, as a terminal tab keeps its
/// terminal, so switching back is instant.
///
/// Without `navigation`, the tab shows only its page: a link clicked there opens in the
/// default browser instead. The page's own scripts may still load other pages.
final class WebPage: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, TabPage {
    let view: PageView
    var root: NSView { view }

    /// Asks for another page for the tab; Change Page… in the page's menu, without navigation.
    var change: (() -> Void)?

    /// What the tab's Surface asks for, as last loaded.
    @Published private(set) var spec: Surface.Web

    @Published private(set) var url: URL?
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var loading = false

    private var observations: [NSKeyValueObservation] = []

    /// The namespace of the tab's Surface. When it is a Host's, the tab browses from that
    /// Host (see HostProxies).
    let namespace: String

    init(_ spec: Surface.Web, namespace: String = "default") {
        self.spec = spec
        self.namespace = namespace
        let configuration = WKWebViewConfiguration()
        if #available(macOS 14, *), SpaceStore.shared.host(named: namespace) != nil {
            configuration.websiteDataStore = HostProxies.shared.store(namespace)
        }
        view = PageView(frame: .zero, configuration: configuration)
        super.init()
        view.page = self
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

    func webView(
        _ webView: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // In a tab on a Host, nothing loads until the Host's proxy runs, and a page on its
        // localhost is loaded as <host>.localhost, which goes through the proxy.
        guard #available(macOS 14, *), let host = SpaceStore.shared.host(named: namespace) else {
            return decidePolicy(webView, action, decisionHandler)
        }
        if action.targetFrame?.isMainFrame == true, let url = action.request.url,
           let onHost = HostProxies.onHost(url, host: host.metadata.name) {
            decisionHandler(.cancel)
            webView.load(URLRequest(url: onHost))
            return
        }
        Task { @MainActor in
            do {
                try await HostProxies.shared.connect(host)
                decidePolicy(webView, action, decisionHandler)
            } catch {
                decisionHandler(.cancel)
                webView.loadHTMLString(Self.errorPage(error.localizedDescription), baseURL: nil)
            }
        }
    }

    private func decidePolicy(
        _ webView: WKWebView,
        _ action: WKNavigationAction,
        _ decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
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

    /// A page that says what went wrong.
    static func errorPage(_ message: String) -> String {
        let text = message.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        return "<pre style=\"font: 13px -apple-system; white-space: pre-wrap; padding: 16px\">\(text)</pre>"
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

/// A page's web view, whose right-click menu has Change Page… when the tab shows one page.
final class PageView: WKWebView {
    weak var page: WebPage?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        guard let page, page.spec.navigation != true, page.change != nil else { return }
        let item = NSMenuItem(title: "Change Page…", action: #selector(changePage), keyEquivalent: "")
        item.target = self
        menu.addItem(.separator())
        menu.addItem(item)
    }

    @objc private func changePage() { page?.change?() }
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
            PageHost(view: page.root)
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

/// Puts a page's view, made once by its `TabPage`, in the SwiftUI layout. It goes in a
/// box of its own, as SwiftUI may make the next box before it drops the last one.
struct PageHost: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ box: NSView, context: Context) {
        guard view.superview !== box else { return }
        view.removeFromSuperview()
        view.frame = box.bounds
        view.autoresizingMask = [.width, .height]
        box.addSubview(view)
    }
}
