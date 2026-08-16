import Foundation
import Observation
import WebKit

/// Drives the built-in browser: the LRU model decides who lives, this controller
/// creates/destroys the `WKWebView`s accordingly.
/// - WEB-02: `WKWebsiteDataStore.default()` — persistent, shared across the whole app,
///   cookies survive relaunches.
/// - WEB-04: Safari user-agent so OAuth flows do not break.
/// - WEB-07: no script injection, no content interception.
@MainActor
@Observable
public final class BrowserController: NSObject {

    public private(set) var model = BrowserTabsModel()
    public var onVisit: ((_ url: String, _ title: String) -> Void)?

    private var webViews: [BrowserTabsModel.TabID: WKWebView] = [:]

    public override init() {
        super.init()
    }

    public var activeWebView: WKWebView? {
        guard let active = model.activeTab else { return nil }
        return webViews[active]
    }

    public var tabs: [BrowserTabsModel.Tab] { model.tabs }
    public var activeTab: BrowserTabsModel.TabID? { model.activeTab }

    public func openTab(urlString: String) {
        guard let url = Self.normalize(urlString) else { return }
        let id = model.openTab(url: url)
        reconcileWebViews()
        webViews[id]?.load(URLRequest(url: url))
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

    /// WEB-06 — address OR search: "github.com/pulls" → https://…; a full URL
    /// passes through as is; words ("claude code hooks") go to a Google
    /// search. An input is an address if it has no space AND
    /// looks like a host (a dot, or localhost).
    nonisolated public static func normalize(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") { return URL(string: trimmed) }
        let looksLikeHost = !trimmed.contains(" ")
            && (trimmed.contains(".") || trimmed.hasPrefix("localhost"))
        if looksLikeHost { return URL(string: "https://" + trimmed) }
        var search = URLComponents(string: "https://www.google.com/search")!
        search.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        return search.url
    }

    /// Reconciles the live webviews with the model's LRU decision:
    /// suspended = the webview is destroyed, the URL stays in the model (WEB-05).
    private func reconcileWebViews() {
        let live = model.liveTabIDs
        for id in webViews.keys where !live.contains(id) {
            webViews[id]?.navigationDelegate = nil
            webViews[id] = nil
        }
        for id in live where webViews[id] == nil {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .default()
            let webView = WKWebView(frame: .zero, configuration: configuration)
            webView.customUserAgent =
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
                + "(KHTML, like Gecko) Version/17.4 Safari/605.1.15"
            webView.navigationDelegate = self
            webViews[id] = webView
            if let url = model.tab(id)?.url {
                webView.load(URLRequest(url: url))   // reactivation: reload (WEB-05)
            }
        }
    }
}

extension BrowserController: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let id = webViews.first(where: { $0.value === webView })?.key,
              let url = webView.url else { return }
        let title = webView.title?.isEmpty == false ? webView.title! : (url.host() ?? "")
        model.update(id, url: url, title: title)
        onVisit?(url.absoluteString, title)
    }
}
