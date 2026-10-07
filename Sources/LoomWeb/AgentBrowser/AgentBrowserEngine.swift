import Foundation
import LoomAPI
import Observation

/// What the app and the side panel ask of a session agent's browser, whatever
/// drives its pages: WebKit (`AgentBrowser`, ADR-0014) or headless Chromium
/// over the DevTools protocol (ADR-0016). The commands, their answers and
/// the panel's caption, width menu, activity and dialog banner are the same.
@MainActor
public protocol AgentBrowserEngine: AnyObject, Observable {
    var engine: APIBrowserEngine { get }
    var profile: AgentBrowserProfile.Kind { get }
    /// What the agent is doing now, or did last (the pill, the dot, the globe).
    var activity: AgentActivity? { get }
    /// The dialog the active page waits on, for the panel's banner.
    var activeDialog: AgentModalState? { get }
    var viewportWidth: ViewportWidth { get }
    /// What the panel shows of the page.
    var panelContent: AgentBrowserPanelContent { get }

    /// Runs `command` after the ones before it, within `deadline`.
    func run(_ command: AgentCommand, options: AgentCommandOptions,
             deadline: ContinuousClock.Instant) async throws -> AgentResult
    /// Pending and running commands fail at once with `reason`.
    func cancelAll(_ reason: String)
    func setNetworkAccess(_ access: AgentNetworkAccess)
    func setViewportWidth(_ width: ViewportWidth)
    /// The panel's banner answered the dialog.
    func answerDialog(accept: Bool, text: String?)
    /// Signs out of everything, empties storage (Settings).
    func clearData() async
    /// The session ended: its pages' processes go, the tabs stay to look at.
    func suspend()
    /// The session was archived: everything goes.
    func tearDown()
}

extension AgentBrowserEngine {
    public func run(_ command: AgentCommand, deadline: ContinuousClock.Instant) async throws -> AgentResult {
        try await run(command, options: AgentCommandOptions(), deadline: deadline)
    }
}

/// The page as the side panel shows it.
@MainActor
public enum AgentBrowserPanelContent {
    /// The user's own browser chrome over WebKit views (BrowserPanelView).
    case webKit(BrowserController)
    /// A live picture of headless Chromium's pages, under the same chrome
    /// (ChromiumBrowserPanelView).
    case chromium(ChromiumAgentSurface)
}

/// Which engine a session's agent browser uses (Settings ▸ Agents).
public enum AgentBrowserEnginePreference: String, CaseIterable, Sendable {
    /// Chromium when Loom finds one, else WebKit.
    case automatic
    case chromium
    case webkit

    public static let defaultsKey = "loom.agents.browserEngine"
    /// Until the person chooses: Chromium when Loom finds one — its own
    /// download, Playwright's headless shell, or a browser chosen in
    /// Settings — else WebKit.
    public static let standard: AgentBrowserEnginePreference = .automatic
    /// For support and the self-test: `webkit` or `chromium`, over Settings.
    public static let environmentKey = "LOOM_AGENT_ENGINE"

    /// The engine a session launching now gets. Chromium only when one can
    /// run; an explicit choice of Chromium without one falls back to WebKit
    /// (the panel says why) rather than leaving the agent without a browser.
    public static func resolve(preference: AgentBrowserEnginePreference?, environment: [String: String],
                               chromiumAvailable: Bool) -> APIBrowserEngine {
        let wanted: AgentBrowserEnginePreference = environment[environmentKey]
            .flatMap(AgentBrowserEnginePreference.init(rawValue:)) ?? preference ?? standard
        switch wanted {
        case .webkit: return .webkit
        case .chromium, .automatic: return chromiumAvailable ? .chromium : .webkit
        }
    }
}
