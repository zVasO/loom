import Foundation
import LoomAPI
import LoomChromium
import Observation
import os

/// A session agent's own browser on headless Chromium (ADR-0015): what the
/// app and the side panel see of `ChromiumAgentCore`. The work happens in the
/// core, off the main thread — `run` only hands the command over; what the
/// panel shows (activity, dialog, width, tabs) comes back as one state at a
/// time, applied here in order by a single main-actor task.
@MainActor
@Observable
public final class ChromiumAgentBrowser {

    public let profile: AgentBrowserProfile.Kind
    /// What the agent is doing, or last did.
    public private(set) var activity: AgentActivity? = nil
    /// The dialog (or file chooser) the current tab waits on: the panel's banner.
    public private(set) var activeDialog: AgentModalState? = nil
    /// The page's width: the panel's, or a CSS width it is scaled to.
    public private(set) var viewportWidth: ViewportWidth
    /// The panel's picture of the pages, and the person's buttons.
    public let surface: ChromiumAgentSurface

    nonisolated private let core: ChromiumAgentCore
    @ObservationIgnored private var consumer: Task<Void, Never>?
    /// A pool of its own (tests): shut down with the browser.
    @ObservationIgnored private var ownedPool: ChromiumPool?

    /// `pool`: the app's — one Chromium per project profile, one shared
    /// private one; this session's tabs are targets of the profile's.
    public init(profile: AgentBrowserProfile.Kind, environment: AgentBrowser.Environment, pool: ChromiumPool) {
        let (stream, continuation) = AsyncStream<ChromiumBrowserState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let logger = Logger(subsystem: "app.loom", category: "agent-browser")
        let core = ChromiumAgentCore(profile: profile, environment: environment, pool: pool, updates: continuation,
                                     log: { message in logger.info("\(message, privacy: .public)") })
        self.profile = profile
        self.viewportWidth = environment.viewportWidth
        self.core = core
        self.surface = ChromiumAgentSurface(core: core)
        // Chromium's events (on its reader queue) poke the core, which publishes.
        core.router.setOnChange { [weak core] in
            Task { await core?.refresh() }
        }
        consumer = Task { [weak self] in
            for await state in stream {
                self?.apply(state)
            }
        }
        Task { await core.refresh() }
    }

    public var engine: APIBrowserEngine { .chromium }
    public var panelContent: AgentBrowserPanelContent { .chromium(surface) }

    // MARK: - Commands

    /// Runs `command` after the ones before it, within `deadline` — in the
    /// core: nothing of it runs on the main thread.
    nonisolated public func run(_ command: AgentCommand, options: AgentCommandOptions,
                                deadline: ContinuousClock.Instant) async throws -> AgentResult {
        try await core.run(command, options: options, deadline: deadline)
    }

    /// Pending and running commands fail at once with `reason`.
    public func cancelAll(_ reason: String) {
        core.cancelAll(reason)
        activity = activity.map { AgentActivity(summary: reason, isRunning: false, at: $0.at) }
    }

    /// Local sites only: Chromium takes it at launch — the app's pool stops
    /// the processes on the old setting; here the refusals and popups follow.
    public func setNetworkAccess(_ access: AgentNetworkAccess) {
        core.setNetworkAccess(access)
    }

    /// Every live page at the width, between the agent's commands.
    public func setViewportWidth(_ width: ViewportWidth) {
        viewportWidth = width
        let core = self.core
        Task { await core.setViewportWidth(width) }
    }

    /// The panel's banner answered the current tab's dialog.
    public func answerDialog(accept: Bool, text: String?) {
        let core = self.core
        Task { await core.answerDialogFromPanel(accept: accept, text: text) }
    }

    /// Signs out of everything, empties storage (Settings).
    public func clearData() async {
        await core.clearData()
    }

    /// The session ended: its pages' targets and its hold on Chromium go,
    /// the tabs stay to look at (the panel or the next command brings one back).
    public func suspend() {
        cancelAll("The session ended.")
        let core = self.core
        Task { await core.suspend() }
    }

    /// The session was archived: everything goes.
    public func tearDown() {
        cancelAll("The session was archived.")
        let core = self.core
        Task { await core.tearDown() }
    }

    // MARK: - State from the core

    private func apply(_ state: ChromiumBrowserState) {
        if activity != state.activity { activity = state.activity }
        if activeDialog != state.activeDialog { activeDialog = state.activeDialog }
        if viewportWidth != state.viewportWidth { viewportWidth = state.viewportWidth }
        surface.apply(state)
    }
}

// MARK: - The engine the app sees

extension ChromiumAgentBrowser: AgentBrowserEngine {}

// MARK: - A browser of its own (tests)

extension ChromiumAgentBrowser {

    /// A browser on a pool of its own over throwaway folders under `root`,
    /// driving the binary at `executablePath` (a chrome-headless-shell, or a
    /// Chrome/Chromium .app or executable): what a test needs without the
    /// app. `shutDown()` ends both. Nothing launches before the first page.
    static func standalone(executablePath: String, root: URL, environment: AgentBrowser.Environment,
                           profile: AgentBrowserProfile.Kind = .private) -> ChromiumAgentBrowser {
        let choice = URL(fileURLWithPath: executablePath)
        let executable = ChromiumLocator().candidates(userChoice: choice).first
            ?? ChromiumExecutable(url: choice, kind: .headlessShell, source: .userChoice)
        let pool = ChromiumPool(profiles: ChromiumProfiles(root: root), network: .open, executable: { executable })
        let browser = ChromiumAgentBrowser(profile: profile, environment: environment, pool: pool)
        browser.ownedPool = pool
        return browser
    }

    /// Everything closed, then the pool's Chromium stopped (a pool of its own only).
    func shutDown() async {
        cancelAll("The session was archived.")
        await core.tearDown()
        if let ownedPool {
            await ownedPool.shutdownAll(grace: .seconds(1))
        }
    }
}
