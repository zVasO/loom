import LoomUI
import SwiftUI
import WebKit

/// Browser panel (WEB-01): address bar, tabs, active webview.
/// Only the chrome is themed by the app — never the web content (THM-09).
public struct BrowserPanelView: View {
    /// Owned by the caller: tabs survive the view coming and going.
    private let controller: BrowserController
    @State private var address = ""
    /// What the empty panel suggests: ⌘T means "new browser" in a stack tab,
    /// but beside a terminal it keeps its stack meaning — only + opens a tab.
    private let emptyHint: String
    private let onVisit: ((String, String) -> Void)?

    public init(controller: BrowserController, emptyHint: String = "⌘T or + to open a tab",
                onVisit: ((String, String) -> Void)? = nil) {
        self.controller = controller
        self.emptyHint = emptyHint
        self.onVisit = onVisit
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { controller.activeWebView?.goBack() } label: { Image(systemName: "chevron.left") }
                Button { controller.activeWebView?.goForward() } label: { Image(systemName: "chevron.right") }
                Button { controller.activeWebView?.reload() } label: { Image(systemName: "arrow.clockwise") }
                TextField("Address or search…", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        controller.navigateActive(to: address)
                    }
                Button {
                    controller.openTab(urlString: address.isEmpty ? "github.com" : address)
                } label: { Image(systemName: "plus") }
                // Only a web address goes to the system: a file: URL handed
                // to NSWorkspace would open — or run — whatever it names.
                if let url = controller.activeWebView?.url, BrowserController.isWebAddress(url) {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: { Image(systemName: "safari") }
                    .help("Open in system browser")
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
                // A container, never the web view itself as the NSView: the
                // same page moves between a stack tab and the side panel, and
                // tearing the old host down must not pull it out of the new.
                ExtensionWebView(webView: webView)
            } else {
                Spacer()
                Text(emptyHint)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .onAppear {
            controller.onVisit = onVisit
            controller.materialize()
        }
        .onChange(of: controller.activeWebView?.url) { _, url in
            if let url { address = url.absoluteString }
        }
    }
}

/// Horizontal browser tab — same language as the stack bar
/// (icon, title, close cross on hover or on the active tab).
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
            Text(title.isEmpty ? "New tab" : title)
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

