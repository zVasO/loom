import AppKit
import Foundation
import LoomExtensions
import Observation
import WebKit

/// One extension's page (ADR-0011): its own web view, its own non-persistent
/// data store, its files served from `loom-ext://<id>/` by a scheme handler,
/// the network shut by a content rule list, and `window.loom` answered by the
/// app through `dispatch`. Deliberately not the browser: `BrowserController`
/// shares the user's cookies (WEB-02) and never injects a script (WEB-07) —
/// an extension must have neither the cookies nor the absence of a bridge.
@MainActor
@Observable
public final class ExtensionWebHost: NSObject {
    public let extensionID: String
    public let webView: WKWebView
    /// A link the user clicked, to be opened in their browser.
    @ObservationIgnored public var onOpenExternal: ((URL) -> Void)?
    /// Why the page is not showing, when it is not.
    public private(set) var loadError: String?
    public private(set) var isLoaded = false

    private let messageHandler: ExtensionMessageHandler
    @ObservationIgnored private var pendingEvents: [BridgeEvent] = []
    @ObservationIgnored private var started = false
    @ObservationIgnored private var ruleListAttached = false
    private static let maxPendingEvents = 64

    /// The rule list compiles once per launch; every host shares it.
    private static var ruleList: WKContentRuleList?

    public init(manifest: ExtensionManifest, root: URL, userScript: String, inspectable: Bool,
                dispatch: @escaping @MainActor (String) async -> String) {
        extensionID = manifest.id
        let schemeHandler = ExtensionSchemeHandler(resolver: ExtensionFileResolver(
            extensionID: manifest.id, root: root, entry: manifest.entry))
        messageHandler = ExtensionMessageHandler(extensionID: manifest.id, dispatch: dispatch)

        let configuration = WKWebViewConfiguration()
        // Never `.default()`: that store holds the user's GitHub and Jira
        // sessions from the Loom browser. What an extension keeps, it keeps
        // through `loom.storage`.
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: ExtensionWebPolicy.scheme)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let controller = WKUserContentController()
        controller.addScriptMessageHandler(messageHandler, contentWorld: .page, name: "loom")
        controller.addUserScript(WKUserScript(source: userScript, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true))
        configuration.userContentController = controller
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isInspectable = inspectable
        self.webView = webView
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    /// Compiles (or reuses) the network-blocking rule list, then loads the
    /// page. Idempotent. Fails closed: without the rule list, nothing loads.
    public func load() {
        guard !started else { return }
        started = true
        loadError = nil
        if ruleListAttached {
            navigateHome()
            return
        }
        if let list = Self.ruleList {
            attach(list)
            return
        }
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: ExtensionWebPolicy.contentRuleListID,
            encodedContentRuleList: ExtensionWebPolicy.contentRuleListJSON
        ) { [weak self] list, error in
            Task { @MainActor in
                guard let self else { return }
                if let list {
                    Self.ruleList = list
                    self.attach(list)
                } else {
                    self.loadError = "The network lock could not be set up (\(error?.localizedDescription ?? "unknown error")); the extension was not loaded."
                }
            }
        }
    }

    private func attach(_ list: WKContentRuleList) {
        if !ruleListAttached {
            webView.configuration.userContentController.add(list)
            ruleListAttached = true
        }
        navigateHome()
    }

    /// Events already queued stay queued: a command sent while the page is
    /// still loading for the first time must reach it.
    private func navigateHome() {
        isLoaded = false
        webView.load(URLRequest(url: ExtensionWebPolicy.url(for: extensionID)))
    }

    /// Loads the page again from its first file — after an edit to a linked
    /// extension, or a failure.
    public func reload() {
        guard started, ruleListAttached else {
            started = false
            load()
            return
        }
        loadError = nil
        pendingEvents.removeAll()
        navigateHome()
    }

    /// Replaces the document-start script — the boot values carry the theme,
    /// so a reload after a theme change starts with the right colours.
    public func updateUserScript(_ source: String) {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true))
    }

    /// Hands an event to the page; held until it has loaded.
    public func emit(_ event: BridgeEvent) {
        guard isLoaded else {
            if pendingEvents.count >= Self.maxPendingEvents { pendingEvents.removeFirst() }
            pendingEvents.append(event)
            return
        }
        webView.evaluateJavaScript(BridgeScripts.emit(event), completionHandler: nil)
    }

    /// Breaks the handler's strong hold on the web view's controller and
    /// stops the page — the host is gone after this.
    public func tearDown() {
        let controller = webView.configuration.userContentController
        controller.removeAllScriptMessageHandlers()
        controller.removeAllUserScripts()
        controller.removeAllContentRuleLists()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        pendingEvents.removeAll()
    }

    private func flushPendingEvents() {
        let events = pendingEvents
        pendingEvents.removeAll()
        for event in events {
            webView.evaluateJavaScript(BridgeScripts.emit(event), completionHandler: nil)
        }
    }

    private func handle(_ decision: ExtensionWebPolicy.NavigationDecision) -> WKNavigationActionPolicy {
        switch decision {
        case .allow:
            return .allow
        case .openExternally(let url):
            onOpenExternal?(url)
            return .cancel
        case .cancel:
            return .cancel
        }
    }
}

extension ExtensionWebHost: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let decision = ExtensionWebPolicy.decide(url: navigationAction.request.url,
                                                 isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true,
                                                 isUserClick: navigationAction.navigationType == .linkActivated,
                                                 extensionID: extensionID)
        decisionHandler(handle(decision))
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoaded = false
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
        flushPendingEvents()
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadError = error.localizedDescription
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                        withError error: Error) {
        // A navigation this host cancelled on purpose is not a failure.
        let nsError = error as NSError
        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 { return }
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
        loadError = error.localizedDescription
    }

    /// WebKit killed the page's process (memory pressure, a crash): reload it.
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isLoaded = false
        webView.reload()
    }
}

extension ExtensionWebHost: WKUIDelegate {
    /// `target="_blank"` and `window.open`: no new window, ever. A link the
    /// user clicked opens in their browser.
    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                        for navigationAction: WKNavigationAction,
                        windowFeatures: WKWindowFeatures) -> WKWebView? {
        let decision = ExtensionWebPolicy.decide(url: navigationAction.request.url, isMainFrame: true,
                                                 isUserClick: navigationAction.navigationType == .linkActivated,
                                                 extensionID: extensionID)
        if case .openExternally(let url) = decision { onOpenExternal?(url) }
        return nil
    }
}

/// Serves the extension's files, synchronously, with the content security
/// policy on every response. Answers its own id only; anything else is a 404.
final class ExtensionSchemeHandler: NSObject, WKURLSchemeHandler {
    let resolver: ExtensionFileResolver

    init(resolver: ExtensionFileResolver) {
        self.resolver = resolver
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let status: Int
        let body: Data
        let contentType: String
        if let resolved = resolver.resolve(url), let data = try? Data(contentsOf: resolved.fileURL) {
            status = 200
            body = data
            contentType = resolved.contentType
        } else {
            status = 404
            body = Data("Not found".utf8)
            contentType = "text/plain; charset=utf-8"
        }
        guard let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ExtensionWebPolicy.responseHeaders(contentType: contentType, length: body.count))
        else {
            urlSchemeTask.didFailWithError(URLError(.cannotParseResponse))
            return
        }
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(body)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // Every task finishes inside `start`: nothing is left to stop.
    }
}

/// `webkit.messageHandlers.loom`: JSON text in, JSON text out. Messages from
/// anywhere but the extension's own top-level page are refused before they
/// reach the app. The extension's identity is this handler's, never the
/// message's.
final class ExtensionMessageHandler: NSObject, WKScriptMessageHandlerWithReply {
    let extensionID: String
    let dispatch: @MainActor (String) async -> String

    init(extensionID: String, dispatch: @escaping @MainActor (String) async -> String) {
        self.extensionID = extensionID
        self.dispatch = dispatch
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard ExtensionWebPolicy.acceptsMessage(isMainFrame: message.frameInfo.isMainFrame,
                                                frameURL: message.frameInfo.request.url,
                                                extensionID: extensionID)
        else {
            replyHandler(nil, "forbidden: the bridge answers the extension's own page only")
            return
        }
        guard let text = message.body as? String else {
            replyHandler(nil, "invalidRequest: the bridge takes JSON text")
            return
        }
        let dispatch = self.dispatch
        Task { @MainActor in
            let reply = await dispatch(text)
            replyHandler(reply, nil)
        }
    }
}
