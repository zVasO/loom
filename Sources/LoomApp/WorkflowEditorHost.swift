import AppKit
import Foundation
import WebKit

/// The workflow editor's page (ADR-0017): the React Flow bundle versioned in
/// `Sources/LoomApp/WorkflowEditor`, served from the app's own resources by
/// `loom-workflows://`, talking to Loom through `webkit.messageHandlers.loomWorkflows`
/// (JSON text in, JSON text out) and hearing back through `loomWorkflowsEvent`.
/// No store, no network: the page's CSP shuts it, and a navigation anywhere
/// else is refused.
@MainActor
final class WorkflowEditorHost: NSObject, WKNavigationDelegate {
    static let scheme = "loom-workflows"
    static let entry = URL(string: "loom-workflows://editor/index.html")!

    let webView: WKWebView
    private var loaded = false
    private var started = false
    private var pending: [String] = []

    /// `dispatch(text)`: a request's JSON text → the reply's JSON text.
    init(dispatch: @escaping @MainActor (String) async -> String) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(WorkflowEditorSchemeHandler(), forURLScheme: Self.scheme)
        let controller = WKUserContentController()
        controller.addScriptMessageHandler(WorkflowEditorMessageHandler(dispatch: dispatch),
                                           contentWorld: .page, name: "loomWorkflows")
        configuration.userContentController = controller
        webView = WKWebView(frame: .zero, configuration: configuration)
        #if DEBUG
        webView.isInspectable = true
        #endif
        super.init()
        webView.navigationDelegate = self
    }

    func load() {
        guard !started else { return }
        started = true
        webView.load(URLRequest(url: Self.entry))
    }

    /// Hands an event to the page — held until it has loaded.
    func emit(_ event: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let json = String(data: data, encoding: .utf8) else { return }
        let script = "window.loomWorkflowsEvent && window.loomWorkflowsEvent(\(json));"
        guard loaded else {
            if pending.count > 32 { pending.removeFirst() }
            pending.append(script)
            return
        }
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        for script in pending { self.webView.evaluateJavaScript(script, completionHandler: nil) }
        pending.removeAll()
    }

    /// Only the editor's own pages; a link elsewhere opens in the user's browser.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        if url.scheme == Self.scheme {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        if url.scheme == "https", navigationAction.navigationType == .linkActivated {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Serves the bundle from the app's resources.
final class WorkflowEditorSchemeHandler: NSObject, WKURLSchemeHandler {
    static var root: URL? { Bundle.module.url(forResource: "WorkflowEditor", withExtension: nil) }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let name = url.lastPathComponent.isEmpty ? "index.html" : url.lastPathComponent
        let allowed = ["index.html": "text/html; charset=utf-8", "editor.js": "text/javascript; charset=utf-8",
                       "editor.css": "text/css; charset=utf-8"]
        let body: Data
        let status: Int
        var type = "text/plain; charset=utf-8"
        if let contentType = allowed[name], let root = Self.root,
           let data = try? Data(contentsOf: root.appendingPathComponent(name)) {
            body = data
            status = 200
            type = contentType
        } else {
            body = Data("Not found".utf8)
            status = 404
        }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": type,
                                                            "Content-Length": "\(body.count)",
                                                            "Cache-Control": "no-store"])
        else {
            urlSchemeTask.didFailWithError(URLError(.cannotParseResponse))
            return
        }
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(body)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

/// `webkit.messageHandlers.loomWorkflows`: answers the editor's own top page only.
final class WorkflowEditorMessageHandler: NSObject, WKScriptMessageHandlerWithReply {
    let dispatch: @MainActor (String) async -> String

    init(dispatch: @escaping @MainActor (String) async -> String) {
        self.dispatch = dispatch
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.scheme == WorkflowEditorHost.scheme,
              let text = message.body as? String else {
            replyHandler(nil, "refused")
            return
        }
        let dispatch = self.dispatch
        Task { @MainActor in
            replyHandler(await dispatch(text), nil)
        }
    }
}
