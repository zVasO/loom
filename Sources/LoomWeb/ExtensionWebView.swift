import AppKit
import SwiftUI
import WebKit

/// Hosts a web view owned by a model — an extension's (`ExtensionWebHost`),
/// a browser tab's (`BrowserController`). A container whose one subview is
/// swapped: switching pages in the same place must never leave the previous
/// one showing, and the web view itself is never the representable's NSView,
/// so tearing an old host down cannot pull the page out of its new one.
public struct ExtensionWebView: NSViewRepresentable {
    let webView: WKWebView
    /// Takes the keyboard once on screen — an overlay must not leave keystrokes
    /// going to the terminal it covers.
    let takesFocus: Bool

    public init(webView: WKWebView, takesFocus: Bool = false) {
        self.webView = webView
        self.takesFocus = takesFocus
    }

    public func makeNSView(context: Context) -> WebViewHostView {
        let container = WebViewHostView()
        container.takesFocus = takesFocus
        container.adopt(webView)
        return container
    }

    public func updateNSView(_ container: WebViewHostView, context: Context) {
        container.takesFocus = takesFocus
        container.update(to: webView)
    }
}

/// The container: it remembers which host last adopted each web view, so a
/// stale host still alive during a transition (the page moving between a
/// stack tab and the side panel) never takes it back from the newer one —
/// and when that newer host leaves the screen, an older one still showing
/// takes the page back.
public final class WebViewHostView: NSView {

    /// The latest host of each web view — weak on both sides.
    @MainActor private static let owners = NSMapTable<WKWebView, WebViewHostView>.weakToWeakObjects()
    private static let releasedNotification = Notification.Name("loom.webViewHostReleased")

    private(set) weak var hosted: WKWebView?
    var takesFocus = false

    public override init(frame: NSRect) {
        super.init(frame: frame)
        NotificationCenter.default.addObserver(self, selector: #selector(hostReleased(_:)),
                                               name: Self.releasedNotification, object: nil)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        NotificationCenter.default.addObserver(self, selector: #selector(hostReleased(_:)),
                                               name: Self.releasedNotification, object: nil)
    }

    /// A new page: adopt it. The same page lost: take it back only when no
    /// other host claimed it since.
    func update(to webView: WKWebView) {
        if hosted !== webView {
            adopt(webView)
            return
        }
        guard webView.superview !== self else { return }
        let owner = Self.owners.object(forKey: webView)
        if owner == nil || owner === self { adopt(webView) }
    }

    func adopt(_ webView: WKWebView) {
        subviews.forEach { $0.removeFromSuperview() }
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        hosted = webView
        Self.owners.setObject(self, forKey: webView)
        if takesFocus {
            Task { @MainActor [webView] in
                webView.window?.makeFirstResponder(webView)
            }
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let webView = hosted else { return }
        let owner = Self.owners.object(forKey: webView)
        if window == nil {
            // Leaving the screen with the page: an older host still on screen
            // gets the chance to show it again.
            if owner === self {
                NotificationCenter.default.post(name: Self.releasedNotification, object: webView)
            }
        } else if webView.superview !== self, owner == nil || owner === self || owner?.window == nil {
            adopt(webView)
        }
    }

    @objc private func hostReleased(_ notification: Notification) {
        guard window != nil, let webView = hosted, notification.object as? WKWebView === webView,
              webView.superview !== self else { return }
        adopt(webView)
    }
}
