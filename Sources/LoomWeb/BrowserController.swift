import Foundation
import Observation
import WebKit

/// The agent's browser creates its own web views (ADR-0014): its store, its
/// scripts, its delegates. A user controller never has one.
@MainActor
protocol BrowserTabEngine: AnyObject {
    func makeWebView(for tab: BrowserTabsModel.TabID) -> WKWebView
    func didRelease(_ webView: WKWebView, tab: BrowserTabsModel.TabID)
    /// A load the controller started itself (a tab created or reactivated).
    func didRequestLoad(_ navigation: WKNavigation?, tab: BrowserTabsModel.TabID)
}

/// Drives the built-in browser: the LRU model decides who lives, this controller
/// creates/destroys the `WKWebView`s accordingly.
///
/// A USER controller — the user's Web panes — is the browser of the spec:
/// - WEB-02: `WKWebsiteDataStore.default()` — persistent, shared across the whole app,
///   cookies survive relaunches.
/// - WEB-04: Safari user-agent so OAuth flows do not break.
/// - WEB-07: no script injection, no content interception.
/// An AGENT controller (ADR-0014) holds the agent's tabs; its web views come
/// from its engine, never from here — it can never fall back to the user's
/// store: without its engine, it creates nothing.
@MainActor
@Observable
public final class BrowserController: NSObject {

    public enum Kind: Sendable {
        case user
        case agent
    }

    public let kind: Kind
    public private(set) var model: BrowserTabsModel
    public var onVisit: ((_ url: String, _ title: String) -> Void)?

    private var webViews: [BrowserTabsModel.TabID: WKWebView] = [:]
    @ObservationIgnored private weak var engine: BrowserTabEngine?

    /// Safari's, so OAuth flows do not refuse the web view (WEB-04).
    nonisolated static let safariUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    /// A user's browser.
    public override init() {
        kind = .user
        model = BrowserTabsModel()
        super.init()
    }

    /// The agent's: fewer live tabs (each is a WebContent process the agent
    /// may leave behind), web views from the engine attached right after.
    init(agentTabs maxLiveTabs: Int) {
        kind = .agent
        model = BrowserTabsModel(maxLiveTabs: maxLiveTabs)
        super.init()
    }

    func attach(engine: BrowserTabEngine) {
        self.engine = engine
    }

    public var activeWebView: WKWebView? {
        guard let active = model.activeTab else { return nil }
        return webViews[active]
    }

    public var tabs: [BrowserTabsModel.Tab] { model.tabs }
    public var activeTab: BrowserTabsModel.TabID? { model.activeTab }

    public func openTab(urlString: String) {
        guard let url = Self.normalize(urlString) else { return }
        model.openTab(url: url)
        // The reconcile creates the webview and loads it — a second load here
        // fetched every new page twice.
        reconcileWebViews()
    }

    /// Restores tabs in the MODEL only: no WKWebView, no request. At launch a
    /// hidden pane used to spawn WebKit processes and fetch pages nobody was
    /// looking at, next to the agents booting (audit 2026-09-22, hot path 11).
    /// The panel materialises them when it appears.
    public func restoreTabs(urlStrings: [String]) {
        for urlString in urlStrings {
            guard let url = Self.normalize(urlString) else { continue }
            model.openTab(url: url)
        }
    }

    /// Creates the live tabs' webviews when the panel shows — idempotent.
    public func materialize() {
        reconcileWebViews()
    }

    public func activate(_ id: BrowserTabsModel.TabID) {
        model.activate(id)
        reconcileWebViews()
    }

    public func close(_ id: BrowserTabsModel.TabID) {
        model.close(id)
        reconcileWebViews()
    }

    public func navigateActive(to urlString: String) {
        guard let url = Self.normalize(urlString), let active = model.activeTab else {
            openTab(urlString: urlString)
            return
        }
        model.update(active, url: url)
        webViews[active]?.load(URLRequest(url: url))
    }

    /// WEB-01 — address OR search: "github.com/pulls" → https://…; a full URL
    /// passes through as is; words ("claude code hooks") go to a Google
    /// search. An input is an address if it has no space AND looks like a
    /// host (a dot, an IPv6 bracket, or a loopback name). A loopback host —
    /// where a dev server listens, almost always in plain http — gets http.
    nonisolated public static func normalize(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") { return URL(string: trimmed) }
        if trimmed.lowercased() == "about:blank" { return URL(string: "about:blank") }
        if !trimmed.contains(" "), let host = LoopbackHost.host(ofAddress: trimmed),
           LoopbackHost.isLoopback(host) {
            return URL(string: "http://" + trimmed)
        }
        let looksLikeHost = !trimmed.contains(" ")
            && (trimmed.contains(".") || trimmed.hasPrefix("["))
        if looksLikeHost { return URL(string: "https://" + trimmed) }
        var search = URLComponents(string: "https://www.google.com/search")!
        search.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        return search.url
    }

    /// An http(s) address — the only kind handed to the system browser.
    nonisolated public static func isWebAddress(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// Reconciles the live webviews with the model's LRU decision:
    /// suspended = the webview is destroyed, the URL stays in the model (WEB-05).
    private func reconcileWebViews() {
        let live = model.liveTabIDs
        for id in webViews.keys where !live.contains(id) {
            if let webView = webViews[id] {
                webView.navigationDelegate = nil
                engine?.didRelease(webView, tab: id)
            }
            webViews[id] = nil
        }
        for id in live where webViews[id] == nil {
            let webView: WKWebView
            switch kind {
            case .user:
                webView = userWebView()
            case .agent:
                // No engine, no web view: never the user's store instead.
                guard let engine else { continue }
                webView = engine.makeWebView(for: id)
            }
            webViews[id] = webView
            if let url = model.tab(id)?.url {
                let navigation = webView.load(URLRequest(url: url))   // reactivation: reload (WEB-05)
                engine?.didRequestLoad(navigation, tab: id)
            }
        }
    }

    private func userWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = Self.safariUserAgent
        webView.navigationDelegate = self
        return webView
    }

    /// A page finished loading: the tab takes its address and title. The
    /// user's web views report here as their delegate; the agent's engine,
    /// their own delegate, forwards.
    func recordFinished(_ webView: WKWebView) {
        guard let id = tabID(of: webView), let url = webView.url else { return }
        let title = webView.title?.isEmpty == false ? webView.title! : (url.host() ?? "")
        model.update(id, url: url, title: title)
        onVisit?(url.absoluteString, title)
    }

    // MARK: - For the agent's engine

    func webView(for tab: BrowserTabsModel.TabID) -> WKWebView? {
        webViews[tab]
    }

    func tabID(of webView: WKWebView) -> BrowserTabsModel.TabID? {
        webViews.first(where: { $0.value === webView })?.key
    }

    /// Opens `url` as is — the caller validated it — and makes it current.
    @discardableResult
    func openTab(url: URL) -> BrowserTabsModel.TabID {
        let id = model.openTab(url: url)
        reconcileWebViews()
        return id
    }

    /// Loads `url` in a live tab; the navigation lets the caller follow it.
    @discardableResult
    func load(_ url: URL, in tab: BrowserTabsModel.TabID) -> WKNavigation? {
        model.update(tab, url: url)
        return webViews[tab]?.load(URLRequest(url: url))
    }

    /// A fresh web view for `tab`, at its current address: the old one's
    /// process may be stuck in a script that never yields.
    func recreateWebView(for tab: BrowserTabsModel.TabID) {
        if let webView = webViews.removeValue(forKey: tab) {
            webView.navigationDelegate = nil
            engine?.didRelease(webView, tab: tab)
        }
        reconcileWebViews()
    }

    /// Every web view released, the tabs kept: `materialize()` brings them back.
    func releaseWebViews() {
        for (id, webView) in webViews {
            webView.navigationDelegate = nil
            engine?.didRelease(webView, tab: id)
        }
        webViews.removeAll()
    }
}

extension BrowserController: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        recordFinished(webView)
    }
}
