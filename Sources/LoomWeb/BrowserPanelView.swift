import LoomUI
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
                    HStack(spacing: 3) {
                        ForEach(controller.tabs, id: \.id) { tab in
                            BrowserTabButton(title: tab.title,
                                             isActive: controller.activeTab == tab.id,
                                             onSelect: { controller.activate(tab.id) },
                                             onClose: { controller.close(tab.id) })
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                }
                .background(DefaultTheme.background)
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

/// Onglet horizontal du navigateur — même langage que la barre de pile
/// (icône, titre, croix au survol ou sur l'actif).
struct BrowserTabButton: View {
    let title: String
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "globe")
                .font(.system(size: 9))
                .foregroundStyle(isActive ? DefaultTheme.accent : DefaultTheme.secondaryText)
            Text(title.isEmpty ? "Nouvel onglet" : title)
                .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive || hovered ? DefaultTheme.primaryText
                                                     : DefaultTheme.secondaryText)
                .lineLimit(1)
                .frame(maxWidth: 150, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            if hovered || isActive {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(hovered ? DefaultTheme.primaryText
                                                 : DefaultTheme.secondaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(isActive ? DefaultTheme.surfaceRaised
                    : hovered ? DefaultTheme.surfaceRaised.opacity(0.5) : .clear,
                    in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .stroke(isActive ? DefaultTheme.cardBorder : .clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

/// La webview vit dans le contrôleur (LRU) ; la vue ne fait que l'héberger.
struct WebViewRepresentable: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
