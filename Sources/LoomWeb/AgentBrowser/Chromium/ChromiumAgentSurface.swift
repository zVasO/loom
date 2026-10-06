import CoreGraphics
import Foundation
import LoomChromium
import Observation

/// The agent's Chromium browser as the side panel shows it (ADR-0015): the
/// main-thread copy of the core's tabs, the current page's connection and
/// session for its live picture, and what the person does from the panel —
/// each an operation the core runs between the agent's commands, and refuses
/// while the agent holds the browser.
@MainActor
@Observable
public final class ChromiumAgentSurface: ChromiumPanelSurface {

    /// The agent's tabs, in strip order (title and address).
    public private(set) var tabs: [BrowserTabsModel.Tab] = []
    public private(set) var activeTab: BrowserTabsModel.TabID? = nil
    public private(set) var isLoading = false
    /// What the page area says over the page ("Starting Chromium…", a
    /// crash, a refused address); nil: the page alone.
    public private(set) var statusMessage: String? = nil
    /// The CSS size the pages lay out at (Fit: the page area; a set width
    /// keeps the panel's aspect).
    public private(set) var viewport: CGSize = .zero
    private var sources: [BrowserTabsModel.TabID: ChromiumScreencastSource] = [:]
    /// Whether the page view last said it was on screen.
    @ObservationIgnored private var viewerOnScreen = false

    private let core: ChromiumAgentCore

    init(core: ChromiumAgentCore) {
        self.core = core
    }

    // MARK: - The live picture

    /// The current tab's browser connection, for its screencast; nil while
    /// it has no page (launching, released, crashed).
    public var connection: CDPConnection? {
        activeTab.flatMap { sources[$0] }?.connection
    }

    /// The current tab's flattened session, with `connection`.
    public var session: CDPSessionID? {
        activeTab.flatMap { sources[$0] }?.session
    }

    public func screencastSource(for tab: BrowserTabsModel.TabID) -> ChromiumScreencastSource? {
        sources[tab]
    }

    /// The page view's area in points: Fit's size, and the height a set
    /// width scales into. Applied to the pages between the agent's commands.
    public func reportPanelSize(_ points: CGSize) {
        let core = self.core
        Task { await core.panelChanged(pageArea: points, onScreen: true) }
    }

    /// The page view came on screen (or left it): shown, a released current
    /// tab comes back.
    public func setVisible(_ visible: Bool) {
        guard visible else { return }
        materialize()
    }

    /// The page view's report: its area at once when it comes on screen and
    /// once a resize settles, and when it leaves. Only coming on screen
    /// brings a released tab back — not every resize, and not a tab that
    /// lost its page while shown (a crashed browser is not relaunched in a
    /// loop by being looked at).
    public func viewerDidChange(pageArea: CGSize, backingScale: CGFloat, onScreen: Bool) {
        let appeared = onScreen && !viewerOnScreen
        viewerOnScreen = onScreen
        guard onScreen else { return }
        reportPanelSize(pageArea)
        if appeared {
            setVisible(true)
        }
    }

    // MARK: - The person's operations

    /// The address bar: the agent browser's rules (http(s) and about:blank,
    /// loopback in http), then local sites only — in the core.
    public func navigate(to address: String) {
        do {
            let url = try AgentNavigationPolicy.navigationURL(address)
            perform(.navigate(url))
        } catch {
            let message = (error as? AgentError)?.message ?? "not an address: \(address)"
            let core = self.core
            Task { await core.flash(message) }
        }
    }

    public func goBack() {
        perform(.goBack)
    }

    public func goForward() {
        perform(.goForward)
    }

    public func reload() {
        perform(.reload)
    }

    public func stopLoading() {
        perform(.stopLoading)
    }

    public func selectTab(_ id: BrowserTabsModel.TabID) {
        perform(.select(id))
    }

    public func closeTab(_ id: BrowserTabsModel.TabID) {
        perform(.close(id))
    }

    public func newTab() {
        perform(.newTab)
    }

    public func activate(_ id: BrowserTabsModel.TabID) {
        selectTab(id)
    }

    public func close(_ id: BrowserTabsModel.TabID) {
        closeTab(id)
    }

    /// The panel appeared: a released current tab comes back.
    public func materialize() {
        guard activeTab != nil else { return }
        perform(.materialize)
    }

    private func perform(_ operation: ChromiumUserOperation) {
        let core = self.core
        Task { await core.perform(operation) }
    }

    // MARK: - State from the core

    func apply(_ state: ChromiumBrowserState) {
        if tabs != state.tabs { tabs = state.tabs }
        if activeTab != state.activeTab { activeTab = state.activeTab }
        if isLoading != state.isLoading { isLoading = state.isLoading }
        if statusMessage != state.statusMessage { statusMessage = state.statusMessage }
        if viewport != state.viewport { viewport = state.viewport }
        if sources != state.sources { sources = state.sources }
    }
}
