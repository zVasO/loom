import LoomAgents
import LoomCore
import LoomUI
import SwiftUI

/// The in-app Settings page (gear icon): general, remappable shortcuts,
/// themes (the famous ones), and per-project theme overrides.
struct SettingsPage: View {
    let model: AppModel

    @AppStorage("loom.terminal.fps") private var fps = 60
    @AppStorage("loom.terminal.copyOnSelect") private var copyOnSelect = false
    @AppStorage(KeyboardPreferences.userDefaultsKey) private var optionAsMeta = false
    @AppStorage("loom.session.restoreOnLaunch") private var restoreOnLaunch = true
    @AppStorage("loom.shortcut.newSession") private var keyNewSession = "n"
    @AppStorage("loom.shortcut.newTab") private var keyNewTab = "t"
    @AppStorage("loom.shortcut.missionControl") private var keyMissionControl = "g"
    @AppStorage("loom.shortcut.palette") private var keyPalette = "k"
    /// The family under the pointer in the grid — what the preview shows.
    @State private var hoveredFamily: String?
    /// Which variant the preview shows; starts on the app's, switchable.
    @State private var previewDark = false
    @State private var importShown = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Settings")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(DefaultTheme.primaryText)

                generalSection
                sessionsSection
                reviewSection
                shortcutsSection
                badgesSection
                themesSection
                projectsSection
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 36).padding(.top, 32).padding(.bottom, 44)
            .frame(maxWidth: .infinity)
        }
        .background(DefaultTheme.background)
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

    // MARK: General

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("General")
            card {
                HStack(spacing: 12) {
                    Text("Terminal refresh rate")
                        .font(.system(size: 13))
                        .foregroundStyle(DefaultTheme.primaryText)
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
                Text("Caps how often terminal frames are produced during streaming. 60 fps is the default; 30 spares the battery or an older Mac; 120 is for a ProMotion display. The first frame of any burst is always immediate.")
                    .font(.system(size: 11))
                    .foregroundStyle(DefaultTheme.secondaryText)
                Divider().overlay(DefaultTheme.cardBorder)
                Toggle(isOn: $copyOnSelect) {
                    Text("Copy terminal selection on release")
                        .font(.system(size: 13))
                        .foregroundStyle(DefaultTheme.primaryText)
                }
                .toggleStyle(.switch)
                Text("Releasing a drag in a session terminal puts the text on the clipboard right away, the way iTerm does. Off, the selection waits for ⌘C. Select everything the pane holds with ⌘⇧A — ⌘A keeps typing into the agent's own field.")
                    .font(.system(size: 11))
                    .foregroundStyle(DefaultTheme.secondaryText)
                Divider().overlay(DefaultTheme.cardBorder)
                Toggle(isOn: $optionAsMeta) {
                    Text("Use Option as Meta key")
                        .font(.system(size: 13))
                        .foregroundStyle(DefaultTheme.primaryText)
                }
                .toggleStyle(.switch)
                Text("⌥ + a letter sends ESC + the letter (Emacs-style bindings). Off, ⌥ stays the compose layer of your keyboard — braces and brackets on AZERTY, dead keys everywhere. ⌥←, ⌥→, ⌥⌫ and ⌥↩ work either way, and ⇧Tab, ⇧↩, Esc, ⌃ shortcuts always reach claude.")
                    .font(.system(size: 11))
                    .foregroundStyle(DefaultTheme.secondaryText)
            }
        }
    }

    // MARK: Sessions

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Sessions")
            card {
                Toggle(isOn: $restoreOnLaunch) {
                    Text("Reopen the last session on launch")
                        .font(.system(size: 13))
                        .foregroundStyle(DefaultTheme.primaryText)
                }
                .toggleStyle(.switch)
                Text("Loom comes back to the project you left and restarts the session you had open. Your other closed sessions keep showing in the sidebar as they always do, and stay asleep until you click one — waking them all would reload every plugin and MCP server at once.")
                    .font(.system(size: 11))
                    .foregroundStyle(DefaultTheme.secondaryText)
            }
        }
    }

    // MARK: Shortcuts

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Shortcuts")
            card {
                shortcutRow("New claude session", key: $keyNewSession)
                Divider().overlay(DefaultTheme.cardBorder)
                shortcutRow("New tab in the stack (terminal / browser)", key: $keyNewTab)
                Divider().overlay(DefaultTheme.cardBorder)
                shortcutRow("Mission Control", key: $keyMissionControl)
                Divider().overlay(DefaultTheme.cardBorder)
                shortcutRow("Go to session (palette)", key: $keyPalette)
                Text("One letter or digit, always combined with ⌘. Menu shortcuts update immediately.")
                    .font(.system(size: 11))
                    .foregroundStyle(DefaultTheme.secondaryText)
            }
        }
    }

    private func shortcutRow(_ label: String, key: Binding<String>) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(DefaultTheme.primaryText)
            Spacer()
            Text("⌘")
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
        }
    }

    // MARK: Review

    private var reviewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Review")
            card {
                Toggle(isOn: Binding(
                    get: { model.reviewWorktreesReadOnly },
                    set: { model.reviewWorktreesReadOnly = $0 })) {
                    Text("Read-only review worktrees")
                        .font(.system(size: 13))
                        .foregroundStyle(DefaultTheme.primaryText)
                }
                .toggleStyle(.switch)
                Text("Guard hooks block commit/push in PR review worktrees — the session can build and test but never lands work on someone else's branch. Applies at the next checkout of each PR.")
                    .font(.system(size: 11))
                    .foregroundStyle(DefaultTheme.secondaryText)
                Divider().overlay(DefaultTheme.cardBorder)
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Clone repositories into")
                            .font(.system(size: 13))
                            .foregroundStyle(DefaultTheme.primaryText)
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
                Text("Where a repository added from the PRs tab is cloned (as <folder>/<name>) before it becomes a project.")
                    .font(.system(size: 11))
                    .foregroundStyle(DefaultTheme.secondaryText)
                if model.hiddenCount > 0 {
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
                Divider().overlay(DefaultTheme.cardBorder)
                Toggle(isOn: Binding(
                    get: { model.reviewSetupCommandEnabled },
                    set: { model.reviewSetupCommandEnabled = $0 })) {
                    Text("Run /\(PRReviewCommand.name) when a review starts")
                        .font(.system(size: 13))
                        .foregroundStyle(DefaultTheme.primaryText)
                }
                .toggleStyle(.switch)
                Text("The command is installed in every review worktree either way; on, it is typed into a fresh review session so claude loads the PR — body, diff, threads, linked issues — and keeps a brief in memory before you point it at lines.")
                    .font(.system(size: 11))
                    .foregroundStyle(DefaultTheme.secondaryText)
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
                TextEditor(text: $setupCommandDraft)
                    .font(.system(size: 11, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 220)
                    .background(DefaultTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(DefaultTheme.cardBorder, lineWidth: 1))
                    .onAppear {
                        setupCommandDraft = model.reviewSetupCommandTemplate ?? PRReviewCommand.defaultTemplate
                    }
                    .onChange(of: setupCommandDraft) { _, draft in
                        model.reviewSetupCommandTemplate = draft
                    }
                Text("Claude Code slash-command markdown: a frontmatter, then the prompt. Placeholders filled at launch: \(PRReviewCommand.placeholders.joined(separator: ", ")). $ARGUMENTS is claude's own — the PR number typed after the command.")
                    .font(.system(size: 11))
                    .foregroundStyle(DefaultTheme.secondaryText)
            }
        }
    }

    @State private var setupCommandDraft = ""

    // MARK: Badges

    @State private var newBadgeName = ""
    @State private var newBadgeColor = Color(red: 0.65, green: 0.55, blue: 0.95)

    private var badgesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Badges")
            card {
                Text("Right-click a session card (sidebar or Mission Control) to assign badges — a session wears as many as you like.")
                    .font(.system(size: 11))
                    .foregroundStyle(DefaultTheme.secondaryText)
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
                Divider().overlay(DefaultTheme.cardBorder)
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
    }

    // MARK: Themes

    /// Appearance, the families, and a preview of whichever family the
    /// pointer is on (else the chosen one) — in either variant.
    private var themesSection: some View {
        let store = ThemeStore.shared
        let previewFamily = hoveredFamily.flatMap { store.family(named: $0) }
            ?? store.family(named: store.globalFamilyName) ?? .loom
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Theme")
            card {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Appearance")
                            .font(.system(size: 13))
                            .foregroundStyle(DefaultTheme.primaryText)
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
            }
            HStack {
                Text("Every theme comes in light and dark; the appearance picks the variant.")
                    .font(.system(size: 11))
                    .foregroundStyle(DefaultTheme.secondaryText)
                Spacer()
                GhostButton("Import from tweakcn…", systemImage: "square.and.arrow.down") {
                    importShown = true
                }
            }
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
            Text("The global theme. Projects below can override it — the app follows the project you are working in.")
                .font(.system(size: 11))
                .foregroundStyle(DefaultTheme.secondaryText)
        }
        .sheet(isPresented: $importShown) {
            ThemeImportSheet()
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

    // MARK: Per-project themes

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Project themes")
            card {
                if model.projects.isEmpty {
                    Text("No project yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(DefaultTheme.secondaryText)
                }
                ForEach(Array(model.projects.enumerated()), id: \.element.id) { index, project in
                    if index > 0 { Divider().overlay(DefaultTheme.cardBorder) }
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
                    }
                }
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
