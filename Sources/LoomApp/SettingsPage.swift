import LoomAgents
import LoomChromium
import LoomCore
import LoomExtensions
import LoomPersistence
import LoomUI
import LoomWeb
import SwiftUI

/// A place on the Settings page: a group (General, Sessions…) or one of its
/// sub-sections. The sidebar lists them and scrolls to one on a click; the
/// page reports which one is at the top so the sidebar follows the scroll.
/// Declared in page order — `allCases` is what "the last one scrolled past"
/// is read against.
enum SettingsAnchor: String, CaseIterable, Identifiable {
    case general, terminal, shortcuts
    case sessions, sessionLaunch, instructions, badges
    case agents, agentTools, agentEngine, agentNetwork, agentPage
    case review, reviewWorktrees, reviewCommand, scheduledReviews
    case appearance, appearanceMode, themes, documents
    case projects
    case extensions

    var id: String { rawValue }

    /// A group of the page and its sub-sections, as the sidebar lists them.
    struct Entry: Identifiable {
        let id: SettingsAnchor
        let items: [SettingsAnchor]
    }

    /// The groups in page order, each with its sub-sections.
    static let groups: [Entry] = [
        Entry(id: .general, items: [.terminal, .shortcuts]),
        Entry(id: .sessions, items: [.sessionLaunch, .instructions, .badges]),
        Entry(id: .agents, items: [.agentTools, .agentEngine, .agentNetwork, .agentPage]),
        Entry(id: .review, items: [.reviewWorktrees, .reviewCommand, .scheduledReviews]),
        Entry(id: .appearance, items: [.appearanceMode, .themes, .documents]),
        Entry(id: .projects, items: []),
        Entry(id: .extensions, items: []),
    ]

    /// The group a sub-section belongs to (a group is its own).
    var group: SettingsAnchor {
        Self.groups.first { $0.id == self || $0.items.contains(self) }?.id ?? self
    }

    var title: String {
        switch self {
        case .general: "General"
        case .terminal: "Terminal"
        case .shortcuts: "Shortcuts"
        case .sessions: "Sessions"
        case .sessionLaunch: "Launch & sidebar"
        case .instructions: "Instructions"
        case .badges: "Badges"
        case .agents: "Agents"
        case .agentTools: "Tools"
        case .agentEngine: "Browser engine"
        case .agentNetwork: "Network"
        case .agentPage: "Page & data"
        case .review: "Code review"
        case .reviewWorktrees: "Worktrees & clones"
        case .reviewCommand: "Setup command"
        case .scheduledReviews: "Scheduled reviews"
        case .appearance: "Appearance"
        case .appearanceMode: "Light & dark"
        case .themes: "Themes"
        case .documents: "Reports"
        case .projects: "Projects"
        case .extensions: "Extensions"
        }
    }

    /// A group's icon, in the sidebar and above its sections.
    var icon: String {
        switch group {
        case .general: "gearshape"
        case .sessions: "square.stack"
        case .agents: "sparkles"
        case .review: "arrow.triangle.pull"
        case .appearance: "paintpalette"
        case .projects: "folder"
        default: "puzzlepiece.extension"
        }
    }

    /// One line under a group's title: what is in it.
    var blurb: String {
        switch group {
        case .general: "The terminal, the keyboard and Loom's shortcuts."
        case .sessions: "How sessions start, what claude is told, and how they are filed."
        case .agents: "What the agents may use, and the browser they drive."
        case .review: "Pull request reviews — by hand or on a schedule."
        case .appearance: "Themes for Loom, for Claude Code and for workflow reports."
        case .projects: "Each project's own theme and agent page width."
        default: "Web pages that plug into Loom."
        }
    }
}

/// Each anchor's top edge in the page's scroll view.
private struct SettingsAnchorOffsets: PreferenceKey {
    static let defaultValue: [SettingsAnchor: CGFloat] = [:]
    static func reduce(value: inout [SettingsAnchor: CGFloat], nextValue: () -> [SettingsAnchor: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private extension View {
    /// Makes the view a target of the sidebar and reports where it sits.
    func settingsAnchor(_ anchor: SettingsAnchor) -> some View {
        id(anchor)
            .background(GeometryReader { geometry in
                Color.clear.preference(
                    key: SettingsAnchorOffsets.self,
                    value: [anchor: geometry.frame(in: .named(SettingsPage.scrollSpace)).minY])
            })
    }
}

/// The in-app Settings page (gear icon): a sidebar of groups and their
/// sections on the left — a click scrolls there, and it follows the scroll —
/// and the settings themselves on the right.
struct SettingsPage: View {
    let model: AppModel
    /// A section to bring into view, asked from elsewhere (a proposed
    /// schedule to review); cleared once shown.
    @Binding var focus: SettingsAnchor?

    static let scrollSpace = "loom.settings.scroll"

    /// The section at the top of the page, highlighted in the sidebar.
    @State private var active: SettingsAnchor = .general
    /// Until then the scroll does not move the highlight: a click's own
    /// animated scroll passes over the sections in between, and the last one
    /// may never reach the top.
    @State private var followScrollAfter = Date.distantPast

    @AppStorage("loom.terminal.fps") private var fps = 60
    @AppStorage("loom.terminal.copyOnSelect") private var copyOnSelect = false
    @AppStorage(KeyboardPreferences.userDefaultsKey) private var optionAsMeta = false
    @AppStorage("loom.session.restoreOnLaunch") private var restoreOnLaunch = true
    @AppStorage("loom.sessions.groupReviews") private var groupReviews = true
    @AppStorage("loom.sessions.groupWorkflows") private var groupWorkflows = true
    @AppStorage(ClaudeThemeSync.enabledKey) private var syncClaudeTheme = false
    @AppStorage("loom.shortcut.newSession") private var keyNewSession = "n"
    @AppStorage("loom.shortcut.newTab") private var keyNewTab = "t"
    @AppStorage("loom.shortcut.missionControl") private var keyMissionControl = "g"
    @AppStorage("loom.shortcut.palette") private var keyPalette = "k"
    @State private var importShown = false
    @State private var clearingAgentData = false
    /// The model reads the same keys (AgentBrowserAPI.swift); AppStorage keeps
    /// the switches showing what was just set.
    @AppStorage("loom.agents.browserTools") private var browserToolsOn = true
    @AppStorage("loom.agents.libraryTools") private var libraryToolsOn = true
    @AppStorage("loom.agents.preapproveLoomTools") private var preapproveOn = true
    @AppStorage("loom.agents.localOnly") private var localOnlyOn = false
    /// Edited here, applied on Return or when the field goes: never a
    /// half-typed list in force.
    @State private var hostsDraft = ""
    @State private var agentDataCleared = false
    /// The model's engine choice, mirrored so the picker shows what was just
    /// set (it applies to sessions started or resumed afterwards).
    @State private var engineChoice: AgentBrowserEnginePreference = .standard
    /// The Chromium Loom finds, looked up when the card shows and after a choice.
    @State private var chromiumStatus: AppModel.AgentChromiumStatus?
    /// Why the download could not be removed, until the next try.
    @State private var chromiumRemoveError: String?
    @State private var removalCandidate: InstalledExtension?

    var body: some View {
        ScrollViewReader { proxy in
            HStack(spacing: 0) {
                sidebar(proxy)
                    .frame(width: 220)
                    .background(DefaultTheme.background)
                Divider().overlay(DefaultTheme.cardBorder)
                GeometryReader { viewport in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 44) {
                            generalGroup
                            sessionsGroup
                            agentsGroup
                            reviewGroup
                            appearanceGroup
                            projectsGroup
                            extensionsGroup
                        }
                        .frame(maxWidth: 760, alignment: .leading)
                        .padding(.horizontal, 36).padding(.top, 28)
                        // Room for the last sections to reach the top when
                        // the sidebar scrolls to them.
                        .padding(.bottom, max(44, viewport.size.height * 0.5))
                        .frame(maxWidth: .infinity)
                    }
                    .coordinateSpace(name: Self.scrollSpace)
                    .onPreferenceChange(SettingsAnchorOffsets.self) { offsets in
                        follow(offsets)
                    }
                }
            }
            .onChange(of: focus, initial: true) {
                guard let focus else { return }
                // Once the page is laid out: a scroll asked for before it is
                // does nothing.
                DispatchQueue.main.async {
                    jump(to: focus, with: proxy, animated: false)
                    self.focus = nil
                }
            }
        }
        .background(DefaultTheme.background)
    }

    // MARK: Navigation

    private func jump(to anchor: SettingsAnchor, with proxy: ScrollViewProxy, animated: Bool = true) {
        active = anchor
        followScrollAfter = Date().addingTimeInterval(0.6)
        if animated {
            withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(anchor, anchor: .top) }
        } else {
            proxy.scrollTo(anchor, anchor: .top)
        }
    }

    /// The last section whose top went past the top of the page.
    private func follow(_ offsets: [SettingsAnchor: CGFloat]) {
        guard Date() >= followScrollAfter else { return }
        let reached = SettingsAnchor.allCases.last(where: { (offsets[$0] ?? .infinity) <= 48 }) ?? .general
        if reached != active { active = reached }
    }

    private func sidebar(_ proxy: ScrollViewProxy) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Settings")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(DefaultTheme.primaryText)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 2)
                ForEach(SettingsAnchor.groups) { entry in
                    VStack(alignment: .leading, spacing: 1) {
                        sidebarRow(entry.id, proxy: proxy)
                        ForEach(entry.items) { item in
                            sidebarRow(item, proxy: proxy)
                        }
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 22)
        }
    }

    private func sidebarRow(_ anchor: SettingsAnchor, proxy: ScrollViewProxy) -> some View {
        let isGroup = anchor.group == anchor
        let isActive = active == anchor
        let inActiveGroup = active.group == anchor.group
        return Button {
            jump(to: anchor, with: proxy)
        } label: {
            HStack(spacing: 8) {
                if isGroup {
                    Image(systemName: anchor.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(inActiveGroup ? DefaultTheme.accent : DefaultTheme.secondaryText)
                        .frame(width: 16)
                }
                Text(anchor.title)
                    .font(.system(size: isGroup ? 12.5 : 12, weight: isGroup ? .semibold : .regular))
                    .foregroundStyle(isActive ? DefaultTheme.accent
                                     : (isGroup ? DefaultTheme.primaryText : DefaultTheme.secondaryText))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, isGroup ? 8 : 32).padding(.trailing, 8)
            .padding(.vertical, isGroup ? 6 : 4)
            .background(isActive ? DefaultTheme.accent.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverSurface()
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: Building blocks

    /// A group's heading: its icon, its title, what is in it.
    private func groupHeader(_ anchor: SettingsAnchor) -> some View {
        HStack(spacing: 12) {
            Image(systemName: anchor.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DefaultTheme.accent)
                .frame(width: 32, height: 32)
                .background(DefaultTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(anchor.title)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(DefaultTheme.primaryText)
                Text(anchor.blurb)
                    .font(.system(size: 12))
                    .foregroundStyle(DefaultTheme.secondaryText)
            }
        }
        .settingsAnchor(anchor)
    }

    /// A group: its heading, then its sections.
    private func group(_ anchor: SettingsAnchor, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            groupHeader(anchor)
            content()
        }
    }

    /// A section of a group: its title, then what it holds.
    private func section(_ anchor: SettingsAnchor, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(anchor.title)
            content()
        }
        .settingsAnchor(anchor)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .kerning(0.8)
            .foregroundStyle(DefaultTheme.secondaryText)
    }

    private func card(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11)
                .stroke(DefaultTheme.cardBorder, lineWidth: 1))
    }

    private var cardDivider: some View {
        Divider().overlay(DefaultTheme.cardBorder)
    }

    /// The explanation under a setting.
    private func detail(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(DefaultTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(DefaultTheme.primaryText)
    }

    /// A switch, and what it does underneath.
    private func toggleRow(_ title: String, isOn: Binding<Bool>, detail text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle(isOn: isOn) { label(title) }
                .toggleStyle(.switch)
            detail(text)
        }
    }

    // MARK: General

    private var generalGroup: some View {
        group(.general) {
            section(.terminal) {
                card {
                    HStack(spacing: 12) {
                        label("Terminal refresh rate")
                        Spacer()
                        Picker("", selection: $fps) {
                            Text("30 fps").tag(30)
                            Text("60 fps").tag(60)
                            Text("120 fps").tag(120)
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .onChange(of: fps) {
                            NotificationCenter.default.post(name: .loomFrameRateChanged, object: nil)
                        }
                    }
                    detail("Caps how often terminal frames are produced during streaming. 60 fps is the default; 30 spares the battery or an older Mac; 120 is for a ProMotion display. The first frame of any burst is always immediate.")
                    cardDivider
                    toggleRow("Copy terminal selection on release", isOn: $copyOnSelect,
                              detail: "Releasing a drag in a session terminal puts the text on the clipboard right away, the way iTerm does. Off, the selection waits for ⌘C. Select everything the pane holds with ⌘⇧A — ⌘A keeps typing into the agent's own field.")
                    cardDivider
                    toggleRow("Use Option as Meta key", isOn: $optionAsMeta,
                              detail: "⌥ + a letter sends ESC + the letter (Emacs-style bindings). Off, ⌥ stays the compose layer of your keyboard — braces and brackets on AZERTY, dead keys everywhere. ⌥←, ⌥→, ⌥⌫ and ⌥↩ work either way, and ⇧Tab, ⇧↩, Esc, ⌃ shortcuts always reach claude.")
                }
            }
            section(.shortcuts) {
                card {
                    shortcutRow("New claude session", key: $keyNewSession)
                    cardDivider
                    shortcutRow("New session in a project of your choice", key: $keyNewSession, shift: true)
                    cardDivider
                    shortcutRow("New tab in the stack (terminal / browser)", key: $keyNewTab)
                    cardDivider
                    shortcutRow("Mission Control", key: $keyMissionControl)
                    cardDivider
                    shortcutRow("Go to session (palette)", key: $keyPalette)
                    detail("One letter or digit, always combined with ⌘. ⌘N starts a session in the current project at once; with ⇧ the same letter asks which project first. Menu shortcuts update immediately.")
                }
            }
        }
    }

    private func shortcutRow(_ title: String, key: Binding<String>, shift: Bool = false) -> some View {
        HStack(spacing: 12) {
            label(title)
            Spacer()
            Text(shift ? "⌘⇧" : "⌘")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DefaultTheme.secondaryText)
            TextField("", text: Binding(
                get: { key.wrappedValue.uppercased() },
                set: { raw in
                    // Keep the LAST typed character, letters/digits only.
                    if let char = raw.lowercased().last(where: { $0.isLetter || $0.isNumber }) {
                        key.wrappedValue = String(char)
                    }
                }))
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .multilineTextAlignment(.center)
                .frame(width: 36, height: 28)
                .background(DefaultTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .stroke(DefaultTheme.cardBorder, lineWidth: 1))
                // The ⇧ row follows ⌘N's letter: shown, not edited apart.
                .disabled(shift)
                .opacity(shift ? 0.6 : 1)
        }
    }

    // MARK: Sessions

    private var sessionsGroup: some View {
        group(.sessions) {
            section(.sessionLaunch) {
                card {
                    toggleRow("Reopen the last session on launch", isOn: $restoreOnLaunch,
                              detail: "Loom comes back to the project you left and restarts the session you had open. Your other closed sessions keep showing in the sidebar as they always do, and stay asleep until you click one — waking them all would reload every plugin and MCP server at once.")
                    cardDivider
                    toggleRow("File PR review sessions under Code Review", isOn: $groupReviews,
                              detail: "Sessions opened from the PRs tab, or wearing a PR badge, gather below the projects in their own foldable section, still grouped by project. Off, they stay with the rest of their project's sessions.")
                    cardDivider
                    toggleRow("File workflow sessions under Workflows", isOn: $groupWorkflows,
                              detail: "A workflow run's orchestrator and its visible steps gather in their own foldable section, one group per run, the orchestrator first. Off, they stay with their project's sessions.")
                }
            }
            section(.instructions) { instructionsCard }
            section(.badges) { badgesCard }
        }
    }

    // MARK: Agents (ADR-0014)

    private func commitHosts() {
        guard hostsDraft != model.agentBrowsersAllowedHosts else { return }
        model.agentBrowsersAllowedHosts = hostsDraft
    }

    private var agentsGroup: some View {
        group(.agents) {
            section(.agentTools) {
                card {
                    toggleRow("Browser tools for agents", isOn: $browserToolsOn,
                              detail: "Each session's agent gets its own browser — shown beside its terminal, on a profile kept per project and never your own cookies (reviews get a private one) — and browser_* tools to open your dev server, click, type, read the console and take screenshots. Off: calls are refused at once, and the agents' Chromium stops; sessions started or resumed afterwards no longer list the tools.")
                    // Through the model: turning them off also cancels what is queued.
                    .onChange(of: browserToolsOn) { _, on in model.agentBrowserToolsEnabled = on }
                    cardDivider
                    toggleRow("Workflow tools in every session", isOn: $libraryToolsOn,
                              detail: "Agents can read your workflows, blocks, experts and scheduled reviews, and propose new ones (loom_library_*). What they save is a proposal: it never runs nor fires until you validate it in Workflows › To review. Off: sessions started or resumed afterwards no longer list these tools.")
                    cardDivider
                    toggleRow("Run Loom's tools without asking", isOn: $preapproveOn,
                              detail: "Claude Code runs Loom's own tools (mcp__loom__…: your session's title, badges and browser) without a permission prompt, so a browser test does not stop at every click. Your own deny rules still apply. Off: Claude Code asks, as for any MCP tool. Applies to sessions started or resumed after the change.")
                }
            }
            section(.agentEngine) {
                card { agentEngineRows }
            }
            section(.agentNetwork) {
                card {
                    toggleRow("Agent browser: local sites only", isOn: $localOnlyOn,
                              detail: "The agents' browsers load from your machine's own addresses (localhost, 127.0.0.1) and the hosts below, nothing else: pages, scripts, images, requests and web sockets — under both engines. WebKit filters every load, with WebRTC and DNS prefetching off where it allows; Chromium sends everything else to a proxy Loom holds that refuses it, with QUIC, WebRTC and DNS prefetching off, and stays closed if that proxy cannot start. Open pages start again under the mode when it is turned on (under Chromium, on any change). The agent's other tools stay under Claude Code's own permissions.")
                    .onChange(of: localOnlyOn) { _, on in model.agentBrowsersLocalOnly = on }
                    if localOnlyOn {
                        TextField("api.example.com, *.staging.example.com", text: $hostsDraft)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                            .onAppear { hostsDraft = model.agentBrowsersAllowedHosts }
                            .onSubmit { commitHosts() }
                            .onDisappear { commitHosts() }
                        let invalid = AgentNetworkRules.parse(hostsDraft).invalid
                        Text(invalid.isEmpty
                             ? "Hosts the app under test needs (its API, its login), comma-separated; Return applies them."
                             : "Not a host name, ignored: " + invalid.joined(separator: ", "))
                            .font(.system(size: 11))
                            .foregroundStyle(invalid.isEmpty ? DefaultTheme.secondaryText : DefaultTheme.danger)
                    }
                }
            }
            section(.agentPage) {
                card {
                    HStack(spacing: 12) {
                        label("Agent browser page width")
                        Spacer()
                        Picker("", selection: Binding<Int>(
                            get: { Self.widthTag(model.agentViewportDefaults.global) },
                            set: { model.setAgentGlobalViewportWidth(Self.width(tag: $0) ?? AgentViewportDefaults.factoryDefault) })) {
                            ForEach(ViewportWidth.presets, id: \.label) { width in
                                Text(width.label).tag(Self.widthTag(width))
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    detail("The width an agent's page opens at in new sessions, unless its project sets its own (Projects, below). A width wider than the panel is scaled into it. The agent's browser_resize and the panel's menu change one session only.")
                    cardDivider
                    HStack(spacing: 10) {
                        GhostButton("Clear agent browser data", systemImage: "trash") {
                            clearingAgentData = true
                            Task {
                                await model.clearAgentBrowserData()
                                clearingAgentData = false
                                agentDataCleared = true
                            }
                        }
                        .disabled(clearingAgentData)
                        if clearingAgentData { ProgressView().controlSize(.small) }
                        if agentDataCleared {
                            Text("Cleared ✓")
                                .font(.system(size: 11))
                                .foregroundStyle(DefaultTheme.secondaryText)
                        }
                    }
                    detail("Signs the agents out of every site they or you logged in to in their browsers — WebKit's and Chromium's — and empties their storage. Your own browser is untouched.")
                }
            }
        }
    }

    /// ADR-0016: which engine drives the agents' pages, and the Chromium found.
    @ViewBuilder
    private var agentEngineRows: some View {
        HStack(spacing: 12) {
            label("Agent browser engine")
            Spacer()
            Picker("", selection: $engineChoice) {
                Text("Automatic").tag(AgentBrowserEnginePreference.automatic)
                Text("Chromium").tag(AgentBrowserEnginePreference.chromium)
                Text("WebKit").tag(AgentBrowserEnginePreference.webkit)
            }
            .labelsHidden()
            .fixedSize()
            .onChange(of: engineChoice) { _, choice in
                model.agentBrowserEngineChoice = choice
                refreshChromiumStatus()
            }
        }
        .onAppear {
            engineChoice = model.agentBrowserEngineChoice
            refreshChromiumStatus()
        }
        if let status = chromiumStatus {
            VStack(alignment: .leading, spacing: 3) {
                Text(status.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(DefaultTheme.primaryText)
                if let path = status.path {
                    Text(path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(DefaultTheme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                if let warning = status.warning {
                    Text(warning)
                        .font(.system(size: 11))
                        .foregroundStyle(DefaultTheme.danger)
                }
                if let hint = status.hint {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(DefaultTheme.secondaryText)
                }
            }
        }
        chromiumDownloadRows
        HStack(spacing: 10) {
            GhostButton("Choose…", systemImage: "folder") { chooseChromium() }
            if chromiumStatus?.hasChoice == true {
                GhostButton("Use automatic search", systemImage: "arrow.uturn.backward") {
                    model.agentChromiumPath = nil
                    refreshChromiumStatus()
                }
            }
        }
        Text("Chromium runs the agent's pages headless, panel shown or not, with real clicks and keys (isTrusted, :hover); WebKit stays the fallback. Automatic picks Chromium when Loom finds chrome-headless-shell (its own download or Playwright's) or the browser chosen here; a full Chrome, Chromium or Edge is used only once chosen. Loom downloads chrome-headless-shell only when you click, from Google's Chrome for Testing, checks it against the checksum built into this version of Loom, and never updates it on its own. Each engine keeps its own logins. Applies to sessions started or resumed after the change.")
            .font(.system(size: 11))
            .foregroundStyle(DefaultTheme.secondaryText)
    }

    private func refreshChromiumStatus() {
        chromiumStatus = model.agentChromiumStatus()
    }

    /// Loom's own chrome-headless-shell: downloaded on a click only (NFR-S),
    /// checked against the SHA-256 this version of Loom pins.
    @ViewBuilder
    private var chromiumDownloadRows: some View {
        let setup = model.chromiumSetup
        let major = setup.pin.version.split(separator: ".").first.map(String.init) ?? setup.pin.version
        Group {
            switch setup.phase {
            case .downloading(let received, let total):
                HStack(spacing: 10) {
                    ProgressView(value: Double(received), total: Double(max(total, 1)))
                        .frame(maxWidth: 240)
                    Text("\(received / 1_000_000) of \(max(total, 1) / 1_000_000) MB")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(DefaultTheme.secondaryText)
                    GhostButton("Cancel", systemImage: "xmark") { setup.cancel() }
                }
            case .verifying, .unpacking, .warming:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(setup.phase == .verifying ? "Checking the download (SHA-256)…"
                         : setup.phase == .unpacking ? "Unpacking…" : "Starting it once…")
                        .font(.system(size: 11))
                        .foregroundStyle(DefaultTheme.secondaryText)
                }
            case .idle, .failed:
                if let record = chromiumStatus?.downloaded {
                    HStack(spacing: 10) {
                        Text("chrome-headless-shell \(record.version) · SHA-256 verified"
                             + (record.signature.map { " · " + $0 } ?? ""))
                            .font(.system(size: 11))
                            .foregroundStyle(DefaultTheme.secondaryText)
                        Spacer()
                        GhostButton("Remove", systemImage: "trash") {
                            chromiumRemoveError = setup.remove(supportDirectory: model.supportDirectory,
                                                               chromiumInUse: model.agentChromiumInUse)
                            refreshChromiumStatus()
                        }
                    }
                } else {
                    GhostButton("Download chrome-headless-shell \(major) (\(setup.pin.sizeDescription))",
                                systemImage: "arrow.down.circle") {
                        chromiumRemoveError = nil
                        setup.download(supportDirectory: model.supportDirectory)
                    }
                }
                if case .failed(let message) = setup.phase {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(DefaultTheme.danger)
                }
                if let chromiumRemoveError {
                    Text(chromiumRemoveError)
                        .font(.system(size: 11))
                        .foregroundStyle(DefaultTheme.danger)
                }
            }
        }
        .onChange(of: setup.phase) { _, phase in
            if phase == .idle { refreshChromiumStatus() }
        }
    }

    /// An .app or a bare executable (chrome-headless-shell): the locator
    /// tells them apart.
    private func chooseChromium() {
        let panel = NSOpenPanel()
        panel.title = "Choose a browser for the agents"
        panel.message = "chrome-headless-shell, Chrome for Testing, Chromium, Google Chrome or Microsoft Edge"
        panel.prompt = "Use"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.agentChromiumPath = url.path
        refreshChromiumStatus()
    }

    // MARK: Session instructions

    @State private var instructionsOn = true
    @State private var instructionsDraft = ""

    /// What every claude session is told on top of its system prompt.
    private var instructionsCard: some View {
        card {
            toggleRow("Give every claude session these instructions", isOn: $instructionsOn,
                      detail: "Appended to claude's system prompt (--append-system-prompt) in every session Loom starts or resumes, reviews included — your own rules for all projects, next to each project's CLAUDE.md. The default tells claude to keep its Loom session's title and badges current through Loom's tools. Applies to sessions started or resumed after the change.")
            .onChange(of: instructionsOn) { _, on in model.sessionInstructionsEnabled = on }
            HStack {
                Text("Instructions")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DefaultTheme.primaryText)
                Spacer()
                if instructionsDraft != SessionInstructions.defaultText {
                    GhostButton("Reset to default", systemImage: "arrow.counterclockwise") {
                        instructionsDraft = SessionInstructions.defaultText
                    }
                }
            }
            PromptEditor(text: $instructionsDraft, minHeight: 120)
                .opacity(instructionsOn ? 1 : 0.5)
                .onChange(of: instructionsDraft) { _, draft in
                    model.sessionInstructionsText = draft
                }
        }
        .onAppear {
            instructionsOn = model.sessionInstructionsEnabled
            instructionsDraft = model.sessionInstructionsText
        }
    }

    // MARK: Code review

    @State private var setupCommandDraft = ""

    private var reviewGroup: some View {
        group(.review) {
            section(.reviewWorktrees) {
                card {
                    toggleRow("Read-only review worktrees", isOn: Binding(
                        get: { model.reviewWorktreesReadOnly },
                        set: { model.reviewWorktreesReadOnly = $0 }),
                              detail: "Guard hooks block commit/push in PR review worktrees — the session can build and test but never lands work on someone else's branch. Applies at the next checkout of each PR.")
                    cardDivider
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            label("Clone repositories into")
                            Text(model.cloneDirectory?.path ?? "Not chosen yet — asked at the first clone")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(DefaultTheme.secondaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        GhostButton("Change…", systemImage: "folder") {
                            if let folder = AppModel.pickFolder(title: "Clone repositories into…") {
                                model.cloneDirectory = folder
                            }
                        }
                    }
                    detail("Where a repository added from the PRs tab is cloned (as <folder>/<name>) before it becomes a project.")
                    if model.hiddenCount > 0 {
                        cardDivider
                        HStack {
                            Text(model.hiddenCount == 1
                                 ? "1 organization or repository hidden in the PRs tab"
                                 : "\(model.hiddenCount) organizations or repositories hidden in the PRs tab")
                                .font(.system(size: 12))
                                .foregroundStyle(DefaultTheme.primaryText)
                            Spacer()
                            GhostButton("Show all", systemImage: "eye") { model.unhideAll() }
                        }
                    }
                }
            }
            section(.reviewCommand) {
                card {
                    toggleRow("Run /\(PRReviewCommand.name) when a review starts", isOn: Binding(
                        get: { model.reviewSetupCommandEnabled },
                        set: { model.reviewSetupCommandEnabled = $0 }),
                              detail: "The command is installed in every review worktree either way; on, it is typed into a fresh review session so claude loads the PR — body, diff, threads, linked issues — and keeps a brief in memory before you point it at lines.")
                    HStack {
                        Text("/\(PRReviewCommand.name) command")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DefaultTheme.primaryText)
                        Spacer()
                        if model.reviewSetupCommandTemplate != nil {
                            GhostButton("Reset to default", systemImage: "arrow.counterclockwise") {
                                model.reviewSetupCommandTemplate = nil
                                setupCommandDraft = PRReviewCommand.defaultTemplate
                            }
                        }
                    }
                    PromptEditor(text: $setupCommandDraft, minHeight: 120)
                        .onAppear {
                            setupCommandDraft = model.reviewSetupCommandTemplate ?? PRReviewCommand.defaultTemplate
                        }
                        .onChange(of: setupCommandDraft) { _, draft in
                            model.reviewSetupCommandTemplate = draft
                        }
                    detail("Claude Code slash-command markdown: a frontmatter, then the prompt. Placeholders filled at launch: \(PRReviewCommand.placeholders.joined(separator: ", ")). $ARGUMENTS is claude's own — the PR number typed after the command.")
                }
            }
            section(.scheduledReviews) {
                ScheduledReviewsSettings(model: model)
            }
        }
    }

    // MARK: Badges

    @State private var newBadgeName = ""
    @State private var newBadgeColor = Color(red: 0.65, green: 0.55, blue: 0.95)

    private var badgesCard: some View {
        card {
            detail("Right-click a session card (sidebar or Mission Control) to assign badges — a session wears as many as you like.")
            ForEach(model.badgeDefinitions) { definition in
                HStack(spacing: 10) {
                    BadgeChip(label: definition.name,
                              color: AppModel.color(hex: definition.colorHex))
                    Spacer()
                    Text(definition.colorHex)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(DefaultTheme.mutedText)
                    HoverIconButton(systemImage: "xmark", help: "Delete this badge") {
                        model.saveBadgeDefinitions(
                            model.badgeDefinitions.filter { $0.name != definition.name })
                    }
                }
            }
            cardDivider
            HStack(spacing: 10) {
                TextField("New badge name…", text: $newBadgeName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(DefaultTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 7))
                    .frame(maxWidth: 220)
                ColorPicker("", selection: $newBadgeColor, supportsOpacity: false)
                    .labelsHidden()
                AccentButton("Add") {
                    let name = newBadgeName.trimmingCharacters(in: .whitespaces).lowercased()
                    guard !name.isEmpty,
                          !model.badgeDefinitions.contains(where: { $0.name == name })
                    else { return }
                    let resolved = NSColor(newBadgeColor).usingColorSpace(.deviceRGB) ?? .gray
                    let hex = String(format: "#%02X%02X%02X",
                                     Int(resolved.redComponent * 255),
                                     Int(resolved.greenComponent * 255),
                                     Int(resolved.blueComponent * 255))
                    model.saveBadgeDefinitions(
                        model.badgeDefinitions
                            + [AppModel.BadgeDefinition(name: name, colorHex: hex)])
                    newBadgeName = ""
                }
            }
        }
    }

    // MARK: Appearance

    /// Appearance, the families, and a preview of whichever family the
    /// pointer is on (else the chosen one) — in either variant.
    private var appearanceGroup: some View {
        let store = ThemeStore.shared
        return group(.appearance) {
            section(.appearanceMode) {
                card {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            label("Appearance")
                            Text(store.appearanceMode == .system
                                 ? "Following macOS — \(store.systemIsDark ? "dark" : "light") right now."
                                 : "Forced \(store.appearanceMode.label.lowercased()), whatever macOS says.")
                                .font(.system(size: 11))
                                .foregroundStyle(DefaultTheme.secondaryText)
                        }
                        Spacer()
                        Picker("", selection: Binding(
                            get: { store.appearanceMode },
                            set: { store.setAppearanceMode($0) })) {
                            ForEach(AppearanceMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    cardDivider
                    toggleRow("Apply the theme to Claude Code", isOn: $syncClaudeTheme,
                              detail: "Claude Code draws its own colours over the terminal. On, Loom writes its themes to ~/.claude/themes (loom-*.json, also listed in /theme) and every session it starts follows the project's theme and appearance — live, even while it runs. Needs Claude Code 2.1.118 or later. Off, the files are removed; sessions restarted after that go back to your own Claude theme.")
                    .onChange(of: syncClaudeTheme) { model.syncClaudeThemes() }
                }
            }
            section(.themes) {
                HStack {
                    detail("Every theme comes in light and dark; the appearance picks the variant. This is the global theme — a project can override it (Projects, below), and the app follows the project you are working in.")
                    Spacer()
                    GhostButton("Import from tweakcn…", systemImage: "square.and.arrow.down") {
                        importShown = true
                    }
                }
                ThemeGallery()
            }
            section(.documents) {
                card {
                    ThemeDocumentSettings()
                }
            }
        }
        .sheet(isPresented: $importShown) {
            ThemeImportSheet()
        }
    }

    // MARK: Projects

    /// A width as a picker's tag: 0 is Fit, -1 the default.
    private static func widthTag(_ width: ViewportWidth?) -> Int {
        switch width {
        case nil: return -1
        case .fit?: return 0
        case .css(let pixels)?: return pixels
        }
    }

    private static func width(tag: Int) -> ViewportWidth? {
        switch tag {
        case -1: return nil
        case 0: return .fit
        default: return .css(tag)
        }
    }

    /// A project's agent page width: the default, or one of the presets —
    /// and a width set earlier that is none of them, as it is.
    private func agentWidthPicker(for project: ProjectRecord) -> some View {
        let own = model.agentViewportDefaults.override(for: project.id.rawValue)
        let choices = ViewportWidth.presets + (own.map { ViewportWidth.presets.contains($0) ? [] : [$0] } ?? [])
        return Picker("", selection: Binding<Int>(
            get: { Self.widthTag(own) },
            set: { model.setAgentDefaultViewportWidth(Self.width(tag: $0), for: project.id) })) {
            Text("Default (\(model.agentViewportDefaults.global.label))").tag(-1)
            ForEach(choices, id: \.label) { width in
                Text(width.label).tag(Self.widthTag(width))
            }
        }
        .labelsHidden()
        .fixedSize()
        .help("The page width this project's agent browsers open at")
    }

    private var projectsGroup: some View {
        group(.projects) {
            card {
                if model.projects.isEmpty {
                    Text("No project yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(DefaultTheme.secondaryText)
                }
                ForEach(Array(model.projects.enumerated()), id: \.element.id) { index, project in
                    if index > 0 { cardDivider }
                    HStack(spacing: 12) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(DefaultTheme.accent)
                        Text(project.name)
                            .font(.system(size: 13))
                            .foregroundStyle(DefaultTheme.primaryText)
                        Spacer()
                        Picker("", selection: Binding<String>(
                            get: { ThemeStore.shared.projectThemeName(project.id) ?? "" },
                            set: { name in
                                ThemeStore.shared.setProjectTheme(name.isEmpty ? nil : name,
                                                                  for: project.id)
                                NotificationCenter.default.post(name: .loomThemeChanged, object: nil)
                            })) {
                            Text("Global theme").tag("")
                            ForEach(ThemeStore.shared.families) { family in
                                Text(family.name).tag(family.name)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .help("This project's theme")
                        Image(systemName: "macwindow")
                            .font(.system(size: 11))
                            .foregroundStyle(DefaultTheme.mutedText)
                            .help("Agent browser page width")
                        agentWidthPicker(for: project)
                    }
                }
            }
        }
    }

    // MARK: Extensions (ADR-0011)

    private var extensionsGroup: some View {
        let extensions = model.extensions
        return group(.extensions) {
            card {
                detail("Web pages that plug into Loom — a Jira board, an inbox, your own tools. Each runs in its own sandboxed web view and reaches only what you approve. See docs/extensions.md to write one.")
                HStack(spacing: 8) {
                    GhostButton("Install from folder…", systemImage: "square.and.arrow.down") {
                        guard let url = AppModel.pickFolder(title: "Choose an extension folder") else { return }
                        extensions.requestInstall(from: url, linking: false)
                    }
                    GhostButton("Link folder (development)…", systemImage: "link") {
                        guard let url = AppModel.pickFolder(title: "Choose the extension you are developing") else { return }
                        extensions.requestInstall(from: url, linking: true)
                    }
                    Spacer()
                }
                if let error = extensions.lastError {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                        Text(error).textSelection(.enabled)
                        Spacer()
                        Button("Dismiss") { extensions.lastError = nil }
                            .buttonStyle(.plain)
                            .foregroundStyle(DefaultTheme.secondaryText)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(DefaultTheme.danger)
                }
                ForEach(extensions.extensions) { installed in
                    cardDivider
                    extensionRow(installed)
                }
                ForEach(extensions.problems) { problem in
                    cardDivider
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(DefaultTheme.danger)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(problem.location.lastPathComponent)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(DefaultTheme.primaryText)
                            Text(problem.message)
                                .font(.system(size: 11))
                                .foregroundStyle(DefaultTheme.secondaryText)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .alert("Remove \(removalCandidate?.manifest.name ?? "the extension")?",
               isPresented: Binding(get: { removalCandidate != nil }, set: { if !$0 { removalCandidate = nil } })) {
            Button("Remove", role: .destructive) {
                if let id = removalCandidate?.id { extensions.remove(id) }
                removalCandidate = nil
            }
            Button("Cancel", role: .cancel) { removalCandidate = nil }
        } message: {
            Text(removalCandidate?.isLinked == true
                 ? "Its settings and Keychain secrets are deleted. Your development folder is left as it is."
                 : "Its files, settings and Keychain secrets are deleted.")
        }
    }

    private func extensionRow(_ installed: InstalledExtension) -> some View {
        let extensions = model.extensions
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: installed.manifest.icon ?? "puzzlepiece.extension")
                    .font(.system(size: 13))
                    .foregroundStyle(DefaultTheme.accent)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(installed.manifest.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(DefaultTheme.primaryText)
                        MonoTag("v\(installed.manifest.version)", color: DefaultTheme.mutedText)
                        if installed.isLinked { MonoTag("linked", systemImage: "link", color: DefaultTheme.mutedText) }
                    }
                    Text(installed.id)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(DefaultTheme.mutedText)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { installed.enabled },
                                         set: { extensions.setEnabled($0, for: installed.id) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            if case .needsConsent(let missing) = installed.status {
                HStack(spacing: 8) {
                    Text("Now asks for: " + missing.summary.joined(separator: "; "))
                        .font(.system(size: 11))
                        .foregroundStyle(DefaultTheme.badgeColor(for: .needsInput))
                    Spacer()
                    GhostButton("Review…") { extensions.requestApproval(of: installed.id) }
                }
            }
            let granted = installed.effectivePermissions.summary
            Text(granted.isEmpty ? "No permission beyond its own page." : granted.joined(separator: " · "))
                .font(.system(size: 11))
                .foregroundStyle(DefaultTheme.secondaryText)
            // ADR-0015: the sites the user granted at use, each revocable.
            if installed.effectivePermissions.optionalNetwork,
               let hosts = extensions.grantedHosts[installed.id], !hosts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("SITES YOU ADDED")
                            .font(.system(size: 10, weight: .semibold))
                            .kerning(0.8)
                            .foregroundStyle(DefaultTheme.secondaryText)
                        Spacer()
                        GhostButton("Revoke All") { extensions.revokeHosts(nil, for: installed.id) }
                    }
                    ForEach(hosts, id: \.self) { host in
                        HStack(spacing: 6) {
                            Text("https://\(host)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(DefaultTheme.primaryText)
                            Spacer()
                            Button {
                                extensions.revokeHosts([host], for: installed.id)
                            } label: {
                                Image(systemName: "xmark.circle")
                                    .font(.system(size: 11))
                                    .foregroundStyle(DefaultTheme.secondaryText)
                            }
                            .buttonStyle(.plain)
                            .help("Revoke \(host)")
                        }
                    }
                }
            }
            HStack(spacing: 4) {
                GhostButton("Reload", systemImage: "arrow.clockwise") { extensions.reload(installed.id) }
                GhostButton("Show in Finder", systemImage: "folder") { extensions.revealInFinder(installed.id) }
                Spacer()
                GhostButton("Remove", systemImage: "trash", role: .destructive) { removalCandidate = installed }
            }
        }
    }
}

/// A family in the picker grid: its two variants side by side — each half
/// on its own background with its signature swatches — so the card shows
/// what the theme looks like by day and by night.
private struct ThemeCard: View {
    let family: ThemeFamily
    let isActive: Bool
    let onSelect: () -> Void
    let onHover: (Bool) -> Void
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                half(family.palette(dark: false))
                half(family.palette(dark: true))
            }
            HStack(spacing: 6) {
                Text(family.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DefaultTheme.primaryText)
                if !family.isBuiltIn {
                    Text("yours")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(DefaultTheme.secondaryText)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(DefaultTheme.surfaceRaised, in: Capsule())
                }
                Spacer()
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(DefaultTheme.accent)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(DefaultTheme.surface)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(isActive ? DefaultTheme.accent : (hovered ? DefaultTheme.accent.opacity(0.5)
                                                              : DefaultTheme.cardBorder),
                    lineWidth: isActive ? 1.5 : 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { inside in
            hovered = inside
            onHover(inside)
        }
        .animation(.hover, value: hovered)
    }

    private func half(_ palette: ThemePalette) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(Array([palette.accent, palette.groupHeader, palette.stateNeedsInput,
                               palette.branch, palette.danger].enumerated()), id: \.offset) { _, swatch in
                    Circle().fill(swatch).frame(width: 9, height: 9)
                }
            }
            Text(palette.isLight ? family.variantLightName : family.variantDarkName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(palette.primaryText)
                .lineLimit(1)
            Text("Aa 0123")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(palette.secondaryText)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.background)
    }
}

/// The theme grid and the preview of whichever family the pointer is on:
/// owning `hoveredFamily` here keeps a card hover from re-rendering the
/// whole Settings page (audit 2026-09-22, P2-20).
private struct ThemeGallery: View {
    /// The family under the pointer in the grid — what the preview shows.
    @State private var hoveredFamily: String?
    /// Which variant the preview shows; starts on the app's, switchable.
    @State private var previewDark = false

    var body: some View {
        let store = ThemeStore.shared
        let previewFamily = hoveredFamily.flatMap { store.family(named: $0) }
            ?? store.family(named: store.globalFamilyName) ?? .loom
        return VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)],
                      alignment: .leading, spacing: 12) {
                ForEach(store.families) { family in
                    ThemeCard(family: family,
                              isActive: store.globalFamilyName == family.name,
                              onSelect: {
                                  store.setGlobalTheme(family.name)
                                  NotificationCenter.default.post(name: .loomThemeChanged, object: nil)
                              },
                              onHover: { inside in
                                  if inside { hoveredFamily = family.name }
                                  else if hoveredFamily == family.name { hoveredFamily = nil }
                              })
                    .contextMenu {
                        if !family.isBuiltIn {
                            Button("Delete “\(family.name)”", role: .destructive) {
                                store.removeFamily(family)
                                NotificationCenter.default.post(name: .loomThemeChanged, object: nil)
                            }
                        }
                    }
                }
            }
            ThemePreview(family: previewFamily, dark: $previewDark, onUse: usePreviewAction(previewFamily))
                .onAppear { previewDark = store.isDark }
        }
    }

    /// "Use this theme" — absent when the previewed family is already the one.
    private func usePreviewAction(_ family: ThemeFamily) -> (() -> Void)? {
        guard family.name != ThemeStore.shared.globalFamilyName else { return nil }
        return {
            ThemeStore.shared.setGlobalTheme(family.name)
            NotificationCenter.default.post(name: .loomThemeChanged, object: nil)
        }
    }
}
