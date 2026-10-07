import AppKit
import LoomChromium
import LoomUI
import SwiftUI

// The agent's Chromium browser in the side panel (ADR-0016): the user's
// browser chrome laid over a live picture of the page instead of a web
// view. Watch-only for now: no click or key reaches the page yet. The bar,
// the buttons and the tabs act through the engine's panel operations — the
// agent's address rules, never while the agent runs a command.

/// What the panel reads and asks of the engine's main-thread copy of its
/// state (`ChromiumAgentSurface`). An `@Observable` surface drives the view
/// through these: SwiftUI tracks the reads whatever the static type.
@MainActor
public protocol ChromiumPanelSurface: AnyObject {
    /// The agent's tabs, in strip order.
    var tabs: [BrowserTabsModel.Tab] { get }
    var activeTab: BrowserTabsModel.TabID? { get }
    var canGoBack: Bool { get }
    var canGoForward: Bool { get }
    var isLoading: Bool { get }
    /// What the page area says over the page ("Starting Chromium…", "This
    /// page crashed.", a refused address); nil: the page alone.
    var statusMessage: String? { get }

    /// The address bar: the agent's rules (http(s), about:blank, local
    /// sites only when set) apply — the engine refuses the rest with a status.
    func navigate(to address: String)
    func newTab()
    func activate(_ id: BrowserTabsModel.TabID)
    func close(_ id: BrowserTabsModel.TabID)
    func goBack()
    func goForward()
    func reload()
    func stopLoading()
    /// The panel appeared: a released current tab comes back.
    func materialize()
    /// The tab's browser connection and page session, for its live picture;
    /// nil while it has none (launching, released, crashed, closed).
    func screencastSource(for tab: BrowserTabsModel.TabID) -> ChromiumScreencastSource?
    /// A page view's area in points, its backing scale, and whether it is on
    /// screen: Fit's emulated size, and the panels shown.
    func viewerDidChange(pageArea: CGSize, backingScale: CGFloat, onScreen: Bool)
}

extension ChromiumPanelSurface {
    public var canGoBack: Bool { true }
    public var canGoForward: Bool { true }
    public var isLoading: Bool { false }
    public var statusMessage: String? { nil }
    public func stopLoading() {}
    public func materialize() {}
}

/// Toolbar, a tab strip whose height never changes, then the page area —
/// the agent's activity and a page's dialog laid over its top.
struct ChromiumBrowserPanelView<PageOverlay: View>: View {
    private let surface: any ChromiumPanelSurface
    private let emptyHint: String
    /// The agent runs a command: the page is its own until it finishes.
    private let agentBusy: Bool
    private let pageOverlay: () -> PageOverlay

    @State private var address = ""
    @FocusState private var addressFocused: Bool

    static var toolbarHeight: CGFloat { 38 }
    static var tabStripHeight: CGFloat { 29 }

    init(surface: any ChromiumPanelSurface, emptyHint: String, agentBusy: Bool,
         @ViewBuilder pageOverlay: @escaping () -> PageOverlay) {
        self.surface = surface
        self.emptyHint = emptyHint
        self.agentBusy = agentBusy
        self.pageOverlay = pageOverlay
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .frame(height: Self.toolbarHeight)
            tabStrip
                .frame(height: Self.tabStripHeight)
                .background(DefaultTheme.background)
            pageArea
                .overlay(alignment: .top) { pageOverlay() }
        }
        // The page view's own report brings a released tab back, once it is
        // really on screen (not merely laid out in an occluded window).
        .onAppear { address = shownAddress }
        .onChange(of: shownAddress) { _, _ in
            if !addressFocused { address = shownAddress }
        }
        .onChange(of: surface.activeTab) { _, _ in
            if !addressFocused { address = shownAddress }
        }
    }

    private var activeURL: URL? {
        guard let active = surface.activeTab else { return nil }
        return surface.tabs.first { $0.id == active }?.url
    }

    /// The current page's address; about:blank shows as an empty bar.
    private var shownAddress: String {
        guard let url = activeURL, url.absoluteString != "about:blank" else { return "" }
        return url.absoluteString
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { surface.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(agentBusy || surface.activeTab == nil || !surface.canGoBack)
                .help("Back")
            Button { surface.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(agentBusy || surface.activeTab == nil || !surface.canGoForward)
                .help("Forward")
            if surface.isLoading {
                Button { surface.stopLoading() } label: { Image(systemName: "xmark") }
                    .disabled(agentBusy)
                    .help("Stop loading")
            } else {
                Button { surface.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(agentBusy || surface.activeTab == nil)
                    .help("Reload")
            }
            TextField("Address or search…", text: $address)
                .textFieldStyle(.roundedBorder)
                .focused($addressFocused)
                .onSubmit { submitAddress() }
                .onExitCommand {
                    address = shownAddress
                    addressFocused = false
                }
                .help("Opens in the agent's browser, under its rules: http(s) only, local sites only when set.")
            Button { surface.newTab() } label: { Image(systemName: "plus") }
                .disabled(agentBusy)
                .help("New tab")
            // Only a web address goes to the system: a file: URL handed to
            // NSWorkspace would open — or run — whatever it names.
            if let url = activeURL, BrowserController.isWebAddress(url) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: { Image(systemName: "safari") }
                .help("Open in system browser")
            }
        }
        .padding(.horizontal, 8)
    }

    /// The engine checks the address and refuses it while the agent runs a
    /// command, both with a status over the page. The bar then follows the
    /// page again.
    private func submitAddress() {
        let typed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return }
        surface.navigate(to: typed)
        addressFocused = false
    }

    // MARK: - Tabs

    /// Always there, even empty: the page area must not change height when
    /// the agent opens its first tab.
    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                ForEach(surface.tabs, id: \.id) { tab in
                    BrowserTabButton(title: tab.title,
                                     isActive: surface.activeTab == tab.id,
                                     onSelect: { if !agentBusy { surface.activate(tab.id) } },
                                     onClose: { if !agentBusy { surface.close(tab.id) } })
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 2)
        }
    }

    // MARK: - Page

    private var pageArea: some View {
        ZStack {
            DefaultTheme.contentBackground
            // There before the first tab: the surface knows the page area
            // the agent's first page opens at.
            ChromiumPageViewRepresentable(
                source: surface.activeTab.flatMap { surface.screencastSource(for: $0) },
                onPageArea: { [surface] size, scale, onScreen in
                    surface.viewerDidChange(pageArea: size, backingScale: scale, onScreen: onScreen)
                })
            if let status = surface.statusMessage {
                Text(status)
                    .font(.system(size: 12))
                    .foregroundStyle(DefaultTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(DefaultTheme.surfaceRaised, in: Capsule())
                    .padding(.horizontal, 16)
                    .allowsHitTesting(false)
            } else if surface.activeTab == nil {
                Text(emptyHint)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}
