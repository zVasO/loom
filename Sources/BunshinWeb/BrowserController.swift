import Foundation
import Observation
import WebKit

/// Pilote le navigateur intégré : le modèle LRU décide qui vit, ce contrôleur
/// crée/détruit les `WKWebView` en conséquence.
/// - WEB-02 : `WKWebsiteDataStore.default()` — persistant, partagé par toute l'app,
///   les cookies survivent aux relances.
/// - WEB-04 : user-agent Safari pour ne pas casser les OAuth.
/// - WEB-07 : aucune injection de script, aucune interception de contenu.
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

    /// « github.com/pulls » → https://github.com/pulls ; une URL complète passe telle quelle.
    static func normalize(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") { return URL(string: trimmed) }
        return URL(string: "https://" + trimmed)
    }

    /// Fait coïncider les webviews vivantes avec la décision LRU du modèle :
    /// suspendu = la webview est détruite, l'URL reste dans le modèle (WEB-05).
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
                webView.load(URLRequest(url: url))   // réactivation : rechargement (WEB-05)
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
