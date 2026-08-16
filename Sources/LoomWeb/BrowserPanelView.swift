import SwiftUI
import WebKit

/// Panneau navigateur (WEB-01) : barre d'adresse, onglets, webview active.
/// Seul le chrome est thémé par l'app — jamais le contenu web (THM-09).
public struct BrowserPanelView: View {
    /// Possédé par l'appelant : les onglets survivent aux allers-retours de vue.
    private let controller: BrowserController
    @State private var address = ""
    private let onVisit: ((String, String) -> Void)?

    public init(controller: BrowserController, onVisit: ((String, String) -> Void)? = nil) {
        self.controller = controller
        self.onVisit = onVisit
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { controller.activeWebView?.goBack() } label: { Image(systemName: "chevron.left") }
                Button { controller.activeWebView?.goForward() } label: { Image(systemName: "chevron.right") }
                Button { controller.activeWebView?.reload() } label: { Image(systemName: "arrow.clockwise") }
                TextField("Adresse ou recherche…", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        controller.navigateActive(to: address)
                    }
                Button {
                    controller.openTab(urlString: address.isEmpty ? "github.com" : address)
                } label: { Image(systemName: "plus") }
                if let url = controller.activeWebView?.url {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: { Image(systemName: "safari") }
                    .help("Ouvrir dans le navigateur système")
                }
            }
            .padding(8)

            if !controller.tabs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(controller.tabs, id: \.id) { tab in
                            HStack(spacing: 4) {
                                Text(tab.title).lineLimit(1)
                                Button { controller.close(tab.id) } label: {
                                    Image(systemName: "xmark").imageScale(.small)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(controller.activeTab == tab.id ? Color.accentColor.opacity(0.25) : .clear,
                                        in: Capsule())
                            .onTapGesture { controller.activate(tab.id) }
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .frame(height: 30)
            }

            if let webView = controller.activeWebView {
                WebViewRepresentable(webView: webView)
            } else {
                Spacer()
                Text("⌘T ou + pour ouvrir un onglet")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .onAppear { controller.onVisit = onVisit }
        .onChange(of: controller.activeWebView?.url) { _, url in
            if let url { address = url.absoluteString }
        }
    }
}

/// La webview vit dans le contrôleur (LRU) ; la vue ne fait que l'héberger.
struct WebViewRepresentable: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
