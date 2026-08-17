import LoomCore
import LoomUI
import SwiftUI

/// The in-app Settings page (gear icon): general, remappable shortcuts,
/// themes (the famous ones), and per-project theme overrides.
struct SettingsPage: View {
    let model: AppModel

    @AppStorage("loom.terminal.fps") private var fps = 30
    @AppStorage("loom.shortcut.newSession") private var keyNewSession = "n"
    @AppStorage("loom.shortcut.newTab") private var keyNewTab = "t"
    @AppStorage("loom.shortcut.missionControl") private var keyMissionControl = "g"
    @AppStorage("loom.shortcut.palette") private var keyPalette = "k"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Settings")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(DefaultTheme.primaryText)

                generalSection
                shortcutsSection
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
                Text("Caps how often terminal frames are produced during streaming. 30 fps is fluid everywhere; 60/120 for fast Macs. The first frame of any burst is always immediate.")
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

    // MARK: Themes

    private var themesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Theme")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)],
                      alignment: .leading, spacing: 12) {
                ForEach(ThemePalette.all, id: \.name) { palette in
                    ThemeCard(palette: palette,
                              isActive: ThemeStore.shared.globalThemeName == palette.name) {
                        ThemeStore.shared.setGlobalTheme(palette.name)
                        NotificationCenter.default.post(name: .loomThemeChanged, object: nil)
                    }
                }
            }
            Text("The global theme. Projects below can override it — the app follows the project you are working in.")
                .font(.system(size: 11))
                .foregroundStyle(DefaultTheme.secondaryText)
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
                            ForEach(ThemePalette.all, id: \.name) { palette in
                                Text(palette.name).tag(palette.name)
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

/// A theme in the picker grid: name + the palette's signature swatches on its
/// own background — the card previews the theme it applies.
private struct ThemeCard: View {
    let palette: ThemePalette
    let isActive: Bool
    let onSelect: () -> Void
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(Array([palette.accent, palette.groupHeader,
                               palette.stateNeedsInput, palette.branch,
                               palette.danger].enumerated()), id: \.offset) { _, swatch in
                    Circle().fill(swatch).frame(width: 12, height: 12)
                }
                Spacer()
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.accent)
                }
            }
            Text(palette.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.primaryText)
            Text("The quick brown fox")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(palette.secondaryText)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(isActive ? palette.accent : (hovered ? palette.accent.opacity(0.5)
                                                         : DefaultTheme.cardBorder),
                    lineWidth: isActive ? 1.5 : 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovered = $0 }
        .animation(.hover, value: hovered)
    }
}
