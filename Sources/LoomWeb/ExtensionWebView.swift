import AppKit
import SwiftUI
import WebKit

/// Hosts an extension's web view, owned by its `ExtensionWebHost`. A
/// container whose one subview is swapped: switching extensions in the same
/// place must never leave the previous page showing.
public struct ExtensionWebView: NSViewRepresentable {
    let webView: WKWebView

    public init(webView: WKWebView) {
        self.webView = webView
    }

    public func makeNSView(context: Context) -> NSView {
        let container = NSView()
        host(in: container)
        return container
    }

    public func updateNSView(_ container: NSView, context: Context) {
        if container.subviews.first !== webView {
            host(in: container)
        }
    }

    private func host(in container: NSView) {
        container.subviews.forEach { $0.removeFromSuperview() }
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}
