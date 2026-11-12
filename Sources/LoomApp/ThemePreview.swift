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

    /// Keyed on the whole family, not its name: a re-imported or replaced
    /// family keeps its name and changes its tokens, and comparing two token
    /// structs is far cheaper than the palette it would otherwise rebuild.
    private final class PaletteCache {
        var family: ThemeFamily?
        var dark: Bool?
        var palette: ThemePalette?
    }

    private var palette: ThemePalette {
        if let cached = cache.palette, cache.family == family, cache.dark == dark { return cached }
        let built = family.palette(dark: dark)
        cache.family = family
        cache.dark = dark
        cache.palette = built
        return built
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DefaultTheme.space(8)) {
            HStack(spacing: DefaultTheme.space(10)) {
                Text(palette.name)
                    .themeFont(size: 12, weight: .semibold)
                    .foregroundStyle(DefaultTheme.primaryText)
                Text("preview")
                    .themeFont(size: 9, weight: .semibold)
                    .foregroundStyle(DefaultTheme.secondaryText)
                    .padding(.horizontal, DefaultTheme.space(6)).padding(.vertical, DefaultTheme.space(1))
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
            if let designSummary {
                Text(designSummary)
                    .themeFont(size: 10.5, design: .monospaced)
                    .foregroundStyle(DefaultTheme.secondaryText)
                    .textSelection(.enabled)
            }
            mockWindow
                .clipShape(RoundedRectangle(cornerRadius: DefaultTheme.radius(10)))
                .overlay(RoundedRectangle(cornerRadius: DefaultTheme.radius(10)).stroke(DefaultTheme.cardBorder, lineWidth: 1))
        }
    }

    /// What the theme brings beyond its colours, as the app will draw it:
    /// the fonts its stacks resolve to on this Mac, its radius, spacing,
    /// letter-spacing and shadow. nil for a theme that draws the charter.
    private var designSummary: String? {
        guard let design = palette.design else { return nil }
        var parts: [String] = []
        if let stack = design.fontSans { parts.append("Sans " + fontLabel(stack)) }
        if let stack = design.fontMono { parts.append("Mono " + fontLabel(stack)) }
        if let radius = design.radius { parts.append("Radius " + String(format: "%g", radius)) }
        if let spacing = design.spacing { parts.append("Spacing " + String(format: "%g", spacing)) }
        if let letterSpacing = design.letterSpacing {
            parts.append("Tracking " + String(format: "%g", letterSpacing) + "em")
        }
        if let shadow = design.shadow, !shadow.isInvisible {
            parts.append("Shadow " + String(format: "%g %g %g %g", shadow.x, shadow.y, shadow.blur, shadow.spread))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    /// The family a stack comes down to here; says so when the one the
    /// theme asks for first could not be had.
    private func fontLabel(_ stack: String) -> String {
        let resolved = ThemeFonts.shared.familyName(for: stack) ?? "system"
        if let wanted = FontStack.namedFamilies(stack).first, !ThemeFonts.shared.isAvailable(wanted) {
            return "\(resolved) (\(wanted) unavailable)"
        }
        return resolved
    }

    // MARK: The mock window

    private var mockWindow: some View {
        VStack(spacing: 0) {
            navbar
            Rectangle().fill(palette.line).frame(height: 1)
            HStack(spacing: 0) {
                sidebar
                Rectangle().fill(palette.line).frame(width: 1)
                content
            }
        }
        .background(palette.contentBackground)
    }

    private var navbar: some View {
        HStack(spacing: palette.space(8)) {
            HStack(spacing: palette.space(5)) {
                ForEach([palette.danger, palette.stateNeedsInput, palette.stateWorking], id: \.self) { light in
                    Circle().fill(light.opacity(0.8)).frame(width: 8, height: 8)
                }
            }
            .padding(.trailing, palette.space(6))
            Text("Loom").themeFont(size: 11, weight: .semibold, palette: palette).foregroundStyle(palette.primaryText)
            ForEach(["Projects", "Sessions", "PRs"], id: \.self) { tab in
                Text(tab)
                    .themeFont(size: 10, weight: tab == "PRs" ? .semibold : .regular, palette: palette)
                    .foregroundStyle(tab == "PRs" ? palette.primaryText : palette.secondaryText)
                    .padding(.horizontal, palette.space(8)).padding(.vertical, palette.space(3))
                    .background(tab == "PRs" ? palette.surfaceRaised : .clear,
                                in: RoundedRectangle(cornerRadius: palette.radius(6)))
            }
            Spacer()
            AppIcon("magnifyingglass", size: 11).foregroundStyle(palette.secondaryText)
            AppIcon("gearshape", size: 11).foregroundStyle(palette.secondaryText)
        }
        .padding(.horizontal, palette.space(10)).padding(.vertical, palette.space(7))
        .background(palette.background)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: palette.space(8)) {
            Text("PROJECTS")
                .themeFont(size: 8, weight: .semibold, kerning: 0.8, palette: palette)
                .foregroundStyle(palette.groupHeader)
            sessionCard("Fix cache invalidation", state: .working, badge: "PR #42")
            sessionCard("Dark mode for settings", state: .needsInput, badge: nil)
            sessionCard("Rename the store", state: .idle, badge: nil)
            sessionCard("Flaky e2e", state: .failed, badge: nil)
            Spacer(minLength: 0)
        }
        .padding(palette.space(10))
        .frame(width: 168, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(palette.background)
    }

    private func sessionCard(_ title: String, state: SessionState, badge: String?) -> some View {
        let color = stateColor(state)
        return VStack(alignment: .leading, spacing: palette.space(4)) {
            HStack(spacing: palette.space(5)) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text(title)
                    .themeFont(size: 10, weight: .medium, palette: palette)
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
            }
            HStack(spacing: palette.space(5)) {
                Text(DefaultTheme.label(for: state))
                    .themeFont(size: 8, weight: .semibold, palette: palette)
                    .foregroundStyle(color)
                if let badge {
                    Text(badge)
                        .themeFont(size: 8, weight: .semibold, design: .monospaced, palette: palette)
                        .foregroundStyle(palette.accent)
                        .padding(.horizontal, palette.space(4)).padding(.vertical, palette.space(1))
                        .background(palette.accent.opacity(0.15), in: Capsule())
                }
                Spacer(minLength: 0)
                Text("loom/fix-cache")
                    .themeFont(size: 7, design: .monospaced, palette: palette)
                    .foregroundStyle(palette.mutedText)
                    .lineLimit(1)
            }
        }
        .padding(palette.space(7))
        .background(palette.surface, in: RoundedRectangle(cornerRadius: palette.radius(6)))
        .overlay(RoundedRectangle(cornerRadius: palette.radius(6)).stroke(palette.line, lineWidth: 1))
        .themeShadow(.sm, radius: 6, palette: palette)
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
        VStack(alignment: .leading, spacing: palette.space(10)) {
            // A PR row: number, title, chips, the verdict buttons.
            HStack(spacing: palette.space(8)) {
                Text("#42")
                    .themeFont(size: 11, weight: .bold, design: .monospaced, palette: palette)
                    .foregroundStyle(palette.accent)
                Text("Fix cache invalidation")
                    .themeFont(size: 11, weight: .semibold, palette: palette)
                    .foregroundStyle(palette.primaryText)
                chip("bug", color: palette.danger)
                HStack(spacing: palette.space(3)) {
                    Text("+12").foregroundStyle(palette.groupHeader)
                    Text("−3").foregroundStyle(palette.danger)
                }
                .themeFont(size: 9, weight: .medium, design: .monospaced, palette: palette)
                Spacer()
                Circle().fill(palette.stateWorking).frame(width: 6, height: 6)
                Text("CI ✓").themeFont(size: 9, weight: .semibold, palette: palette).foregroundStyle(palette.stateWorking)
            }
            HStack(spacing: palette.space(8)) {
                Text("Review comment…")
                    .themeFont(size: 10, palette: palette)
                    .foregroundStyle(palette.mutedText)
                    .padding(.horizontal, palette.space(8)).padding(.vertical, palette.space(5))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.surface, in: RoundedRectangle(cornerRadius: palette.radius(6)))
                    .overlay(RoundedRectangle(cornerRadius: palette.radius(6)).stroke(palette.line, lineWidth: 1))
                Text("Approve")
                    .themeFont(size: 10, weight: .semibold, palette: palette)
                    .foregroundStyle(palette.accentText)
                    .padding(.horizontal, palette.space(9)).padding(.vertical, palette.space(5))
                    .background(palette.accent, in: RoundedRectangle(cornerRadius: palette.radius(6)))
                Text("Request changes")
                    .themeFont(size: 10, palette: palette)
                    .foregroundStyle(palette.secondaryText)
                    .padding(.horizontal, palette.space(8)).padding(.vertical, palette.space(5))
                    .background(palette.surfaceRaised, in: RoundedRectangle(cornerRadius: palette.radius(6)))
            }
            diff
            terminal
        }
        .padding(palette.space(10))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func chip(_ text: String, color: Color) -> some View {
        HStack(spacing: palette.space(3)) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(text).themeFont(size: 8, weight: .medium, palette: palette)
        }
        .foregroundStyle(palette.secondaryText)
        .padding(.horizontal, palette.space(5)).padding(.vertical, palette.space(2))
        .background(palette.surfaceRaised, in: Capsule())
    }

    private var diff: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: palette.space(6)) {
                AppIcon("chevron.down", size: 8.5)
                    .foregroundStyle(palette.secondaryText)
                Text("Sources/Cache.swift")
                    .themeFont(size: 9, weight: .semibold, design: .monospaced, palette: palette)
                    .foregroundStyle(palette.primaryText)
                Spacer()
                Text("@@ -12,4 +12,5 @@")
                    .themeFont(size: 8, design: .monospaced, palette: palette)
                    .foregroundStyle(palette.branch)
            }
            .padding(.horizontal, palette.space(8)).padding(.vertical, palette.space(5))
            .background(palette.surfaceRaised)
            diffLine(" ", "func invalidate(_ key: Key) {", tint: .clear)
            diffLine("-", "    cache[key] = nil", tint: palette.danger.opacity(0.14))
            diffLine("+", "    cache.removeValue(forKey: key)", tint: palette.groupHeader.opacity(0.14))
            diffLine("+", "    generation += 1", tint: palette.groupHeader.opacity(0.14))
        }
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: palette.radius(6)))
        .overlay(RoundedRectangle(cornerRadius: palette.radius(6)).stroke(palette.line, lineWidth: 1))
    }

    private func diffLine(_ marker: String, _ code: String, tint: Color) -> some View {
        HStack(spacing: palette.space(6)) {
            Text(marker)
                .frame(width: 10)
                .foregroundStyle(marker == "+" ? palette.groupHeader
                                 : marker == "-" ? palette.danger : palette.mutedText)
            Text(code).foregroundStyle(palette.primaryText.opacity(marker == " " ? 0.75 : 1))
            Spacer(minLength: 0)
        }
        .themeFont(size: 9, design: .monospaced, palette: palette)
        .padding(.horizontal, palette.space(8)).padding(.vertical, palette.space(2))
        .background(tint)
    }

    /// The terminal, with its 16 ANSI colours — the one part a theme does
    /// not paint yet; shown so the whole window is judged together.
    private var terminal: some View {
        VStack(alignment: .leading, spacing: palette.space(5)) {
            HStack(spacing: 0) {
                Text("❯ ").foregroundStyle(palette.accent)
                Text("swift test --filter LoomUITests").foregroundStyle(palette.primaryText)
            }
            Text("✔ 42 tests passed in 1.3 s").foregroundStyle(palette.stateWorking)
            HStack(spacing: palette.space(3)) {
                ForEach(Array(DefaultTheme.ansiPalette.enumerated()), id: \.offset) { _, color in
                    RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 12, height: 8)
                }
            }
        }
        .themeFont(size: 9, design: .monospaced, palette: palette)
        .padding(palette.space(8))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.background, in: RoundedRectangle(cornerRadius: palette.radius(6)))
        .overlay(RoundedRectangle(cornerRadius: palette.radius(6)).stroke(palette.line, lineWidth: 1))
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
        VStack(alignment: .leading, spacing: DefaultTheme.space(14)) {
            HStack {
                Text("Import a theme")
                    .themeFont(size: 15, weight: .semibold)
                    .foregroundStyle(DefaultTheme.primaryText)
                Spacer()
                GhostButton("Close") { dismiss() }
            }
            Text("A tweakcn theme name (modern-minimal), its URL (tweakcn.com/themes/… or …/r/themes/….json), or the CSS from tweakcn's Code export — any shadcn theme's :root { … } .dark { … } works. Loom follows it to the letter: colours, borders, radius, spacing, fonts, letter-spacing and shadows. The fonts it names are fetched from Google Fonts when this Mac does not have them.")
                .themeFont(size: 11)
                .foregroundStyle(DefaultTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $input)
                .themeFont(size: 11, design: .monospaced)
                .foregroundStyle(DefaultTheme.primaryText)
                .scrollContentBackground(.hidden)
                .padding(DefaultTheme.space(8))
                .frame(height: family == nil ? 160 : 72)
                .background(DefaultTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: DefaultTheme.radius(6)))
                .overlay(RoundedRectangle(cornerRadius: DefaultTheme.radius(6)).stroke(DefaultTheme.cardBorder, lineWidth: 1))
            HStack(spacing: DefaultTheme.space(8)) {
                AccentButton(importing ? "Importing…" : "Import", systemImage: "square.and.arrow.down") {
                    runImport()
                }
                .disabled(importing || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if importing { ProgressView().controlSize(.small) }
                if let error {
                    Text(error)
                        .themeFont(size: 11)
                        .foregroundStyle(DefaultTheme.danger)
                        .textSelection(.enabled)
                }
                Spacer()
            }
            if let family {
                Divider().overlay(DefaultTheme.cardBorder)
                HStack(spacing: DefaultTheme.space(10)) {
                    Text("Name").themeFont(size: 12).foregroundStyle(DefaultTheme.secondaryText)
                    TextField("", text: $name)
                        .textFieldStyle(.plain)
                        .themeFont(size: 12)
                        .padding(.horizontal, DefaultTheme.space(8)).padding(.vertical, DefaultTheme.space(6))
                        .background(DefaultTheme.surface, in: RoundedRectangle(cornerRadius: DefaultTheme.radius(6)))
                        .overlay(RoundedRectangle(cornerRadius: DefaultTheme.radius(6)).stroke(DefaultTheme.cardBorder, lineWidth: 1))
                    Spacer()
                    AccentButton("Save and use", systemImage: "checkmark") { save(family) }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if family.light == family.dark {
                    Text("Only one variant was found — it serves both light and dark.")
                        .themeFont(size: 11)
                        .foregroundStyle(DefaultTheme.badgeColor(for: .needsInput))
                }
                ThemePreview(family: named(family), dark: $dark)
            }
        }
        .padding(DefaultTheme.space(20))
        .frame(width: 760)
        .frame(minHeight: 360)
        .background(DefaultTheme.background)
        .preferredColorScheme(DefaultTheme.colorScheme)
        .font(DefaultTheme.bodyFont)
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
