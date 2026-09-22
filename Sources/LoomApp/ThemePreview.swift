import LoomCore
import LoomUI
import SwiftUI

/// A family shown on mock components, in whichever variant the switch
/// says — without touching the app's own palette. Everything here paints
/// with the palette it is given, never with `DefaultTheme`: that is what
/// lets a theme be previewed before it is chosen.
struct ThemePreview: View {
    let family: ThemeFamily
    @Binding var dark: Bool
    /// "Use this theme" — nil when the family is already the global one.
    var onUse: (() -> Void)?

    /// Built once per (family, variant), not once per read: the mock
    /// components read it some sixty times per pass.
    @State private var cache = PaletteCache()

    private final class PaletteCache {
        var family: String?
        var dark: Bool?
        var palette: ThemePalette?
    }

    private var palette: ThemePalette {
        if let cached = cache.palette, cache.family == family.name, cache.dark == dark { return cached }
        let built = family.palette(dark: dark)
        cache.family = family.name
        cache.dark = dark
        cache.palette = built
        return built
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(palette.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DefaultTheme.primaryText)
                Text("preview")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DefaultTheme.secondaryText)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(DefaultTheme.surfaceRaised, in: Capsule())
                Spacer()
                // The switch previews the other variant; the app's own
                // appearance is untouched.
                Picker("", selection: $dark) {
                    Label("Light", systemImage: "sun.max").tag(false)
                    Label("Dark", systemImage: "moon").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                if let onUse {
                    AccentButton("Use this theme", action: onUse)
                }
            }
            mockWindow
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(DefaultTheme.cardBorder, lineWidth: 1))
        }
    }

    // MARK: The mock window

    private var mockWindow: some View {
        VStack(spacing: 0) {
            navbar
            Rectangle().fill(palette.cardBorder).frame(height: 1)
            HStack(spacing: 0) {
                sidebar
                Rectangle().fill(palette.cardBorder).frame(width: 1)
                content
            }
        }
        .background(palette.contentBackground)
    }

    private var navbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                ForEach([palette.danger, palette.stateNeedsInput, palette.stateWorking], id: \.self) { light in
                    Circle().fill(light.opacity(0.8)).frame(width: 8, height: 8)
                }
            }
            .padding(.trailing, 6)
            Text("Loom").font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.primaryText)
            ForEach(["Projects", "Sessions", "PRs"], id: \.self) { tab in
                Text(tab)
                    .font(.system(size: 10, weight: tab == "PRs" ? .semibold : .regular))
                    .foregroundStyle(tab == "PRs" ? palette.primaryText : palette.secondaryText)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(tab == "PRs" ? palette.surfaceRaised : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
            }
            Spacer()
            Image(systemName: "magnifyingglass").font(.system(size: 9)).foregroundStyle(palette.secondaryText)
            Image(systemName: "gearshape").font(.system(size: 9)).foregroundStyle(palette.secondaryText)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(palette.background)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PROJECTS")
                .font(.system(size: 8, weight: .semibold)).kerning(0.8)
                .foregroundStyle(palette.groupHeader)
            sessionCard("Fix cache invalidation", state: .working, badge: "PR #42")
            sessionCard("Dark mode for settings", state: .needsInput, badge: nil)
            sessionCard("Rename the store", state: .idle, badge: nil)
            sessionCard("Flaky e2e", state: .failed, badge: nil)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: 168, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(palette.background)
    }

    private func sessionCard(_ title: String, state: SessionState, badge: String?) -> some View {
        let color = stateColor(state)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
            }
            HStack(spacing: 5) {
                Text(DefaultTheme.label(for: state))
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(color)
                if let badge {
                    Text(badge)
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundStyle(palette.accent)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(palette.accent.opacity(0.15), in: Capsule())
                }
                Spacer(minLength: 0)
                Text("loom/fix-cache")
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundStyle(palette.mutedText)
                    .lineLimit(1)
            }
        }
        .padding(7)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(palette.cardBorder, lineWidth: 1))
    }

    private func stateColor(_ state: SessionState) -> Color {
        switch state {
        case .working: palette.stateWorking
        case .needsInput: palette.stateNeedsInput
        case .failed: palette.danger
        default: palette.stateIdle
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            // A PR row: number, title, chips, the verdict buttons.
            HStack(spacing: 8) {
                Text("#42")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(palette.accent)
                Text("Fix cache invalidation")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.primaryText)
                chip("bug", color: palette.danger)
                HStack(spacing: 3) {
                    Text("+12").foregroundStyle(palette.groupHeader)
                    Text("−3").foregroundStyle(palette.danger)
                }
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                Spacer()
                Circle().fill(palette.stateWorking).frame(width: 6, height: 6)
                Text("CI ✓").font(.system(size: 9, weight: .semibold)).foregroundStyle(palette.stateWorking)
            }
            HStack(spacing: 8) {
                Text("Review comment…")
                    .font(.system(size: 10))
                    .foregroundStyle(palette.mutedText)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.surface, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.cardBorder, lineWidth: 1))
                Text("Approve")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.accentText)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(palette.accent, in: RoundedRectangle(cornerRadius: 7))
                Text("Request changes")
                    .font(.system(size: 10))
                    .foregroundStyle(palette.secondaryText)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 7))
            }
            diff
            terminal
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func chip(_ text: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(text).font(.system(size: 8, weight: .medium))
        }
        .foregroundStyle(palette.secondaryText)
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(palette.surfaceRaised, in: Capsule())
    }

    private var diff: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                    .foregroundStyle(palette.secondaryText)
                Text("Sources/Cache.swift")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(palette.primaryText)
                Spacer()
                Text("@@ -12,4 +12,5 @@")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(palette.branch)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(palette.surfaceRaised)
            diffLine(" ", "func invalidate(_ key: Key) {", tint: .clear)
            diffLine("-", "    cache[key] = nil", tint: palette.danger.opacity(0.14))
            diffLine("+", "    cache.removeValue(forKey: key)", tint: palette.groupHeader.opacity(0.14))
            diffLine("+", "    generation += 1", tint: palette.groupHeader.opacity(0.14))
        }
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(palette.cardBorder, lineWidth: 1))
    }

    private func diffLine(_ marker: String, _ code: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Text(marker)
                .frame(width: 10)
                .foregroundStyle(marker == "+" ? palette.groupHeader
                                 : marker == "-" ? palette.danger : palette.mutedText)
            Text(code).foregroundStyle(palette.primaryText.opacity(marker == " " ? 0.75 : 1))
            Spacer(minLength: 0)
        }
        .font(.system(size: 9, design: .monospaced))
        .padding(.horizontal, 8).padding(.vertical, 2)
        .background(tint)
    }

    /// The terminal, with its 16 ANSI colours — the one part a theme does
    /// not paint yet; shown so the whole window is judged together.
    private var terminal: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 0) {
                Text("❯ ").foregroundStyle(palette.accent)
                Text("swift test --filter LoomUITests").foregroundStyle(palette.primaryText)
            }
            Text("✔ 42 tests passed in 1.3 s").foregroundStyle(palette.stateWorking)
            HStack(spacing: 3) {
                ForEach(Array(DefaultTheme.ansiPalette.enumerated()), id: \.offset) { _, color in
                    RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 12, height: 8)
                }
            }
        }
        .font(.system(size: 9, design: .monospaced))
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.background, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(palette.cardBorder, lineWidth: 1))
    }
}

/// Import a tweakcn (or any shadcn) theme: a name, a URL or the CSS export
/// pasted in one field; the family is previewed in both variants, named,
/// then saved and applied.
struct ThemeImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var importing = false
    @State private var error: String?
    @State private var family: ThemeFamily?
    @State private var name = ""
    @State private var dark = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Import a theme")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DefaultTheme.primaryText)
                Spacer()
                GhostButton("Close") { dismiss() }
            }
            Text("A tweakcn theme name (modern-minimal), its URL (tweakcn.com/themes/… or …/r/themes/….json), or the CSS from tweakcn's Code export — any shadcn theme's :root { … } .dark { … } works.")
                .font(.system(size: 11))
                .foregroundStyle(DefaultTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $input)
                .font(.system(size: 11, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: family == nil ? 160 : 72)
                .background(DefaultTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(DefaultTheme.cardBorder, lineWidth: 1))
            HStack(spacing: 8) {
                AccentButton(importing ? "Importing…" : "Import", systemImage: "square.and.arrow.down") {
                    runImport()
                }
                .disabled(importing || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if importing { ProgressView().controlSize(.small) }
                if let error {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(DefaultTheme.danger)
                        .textSelection(.enabled)
                }
                Spacer()
            }
            if let family {
                Divider().overlay(DefaultTheme.cardBorder)
                HStack(spacing: 10) {
                    Text("Name").font(.system(size: 12)).foregroundStyle(DefaultTheme.secondaryText)
                    TextField("", text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(DefaultTheme.cardBorder, lineWidth: 1))
                    Spacer()
                    AccentButton("Save and use", systemImage: "checkmark") { save(family) }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if family.light == family.dark {
                    Text("Only one variant was found — it serves both light and dark.")
                        .font(.system(size: 11))
                        .foregroundStyle(DefaultTheme.badgeColor(for: .needsInput))
                }
                ThemePreview(family: named(family), dark: $dark)
            }
        }
        .padding(20)
        .frame(width: 760)
        .frame(minHeight: 360)
        .background(DefaultTheme.background)
        .preferredColorScheme(DefaultTheme.colorScheme)
        .onAppear { dark = ThemeStore.shared.isDark }
    }

    private func named(_ family: ThemeFamily) -> ThemeFamily {
        var named = family
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { named.name = trimmed }
        return named
    }

    private func runImport() {
        importing = true
        error = nil
        Task {
            do {
                let imported = try await ThemeStore.shared.importTweakcn(input)
                family = imported
                name = imported.name
            } catch {
                family = nil
                self.error = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            }
            importing = false
        }
    }

    private func save(_ family: ThemeFamily) {
        let final = named(family)
        do {
            try ThemeStore.shared.addFamily(final)
            ThemeStore.shared.setGlobalTheme(final.name)
            NotificationCenter.default.post(name: .loomThemeChanged, object: nil)
            dismiss()
        } catch {
            self.error = "Could not save the theme: \(error.localizedDescription)"
        }
    }
}
