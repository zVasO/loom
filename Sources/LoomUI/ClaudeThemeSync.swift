import Foundation
import LoomCore

// MARK: - Export: a Loom palette as a Claude Code theme

/// Loom's palette as a Claude Code custom theme (ADR-0013): a JSON file under
/// `~/.claude/themes/`, `{ name, base, overrides }`, selected by the setting
/// `theme: "custom:<slug>"`. Claude watches that folder and reloads a changed
/// file live — so a session pointed at a stable slug follows whatever Loom
/// writes there. Pure: tokens in, bytes out.
public enum ClaudeThemeExport {

    /// Claude's colour tokens, from Loom's. What is not listed falls through
    /// to the `base` preset — which matches the palette's lightness.
    public static func overrides(for tokens: ThemeTokens) -> [String: String] {
        let mix: (String, String, Double) -> String = { ThemeTokens.mix($0, with: $1, amount: $2) }
        let pane = tokens.contentBackground
        let promptBorder = mix(tokens.cardBorder, tokens.mutedText, 0.5)
        return [
            // Accent and text.
            "claude": tokens.accent,
            "claudeShimmer": mix(tokens.accent, tokens.primaryText, 0.35),
            "text": tokens.primaryText,
            "inverseText": tokens.background,
            "inactive": tokens.mutedText,
            "inactiveShimmer": tokens.secondaryText,
            "subtle": mix(tokens.cardBorder, tokens.mutedText, 0.4),
            "suggestion": tokens.accent,
            "permission": tokens.accent,
            "permissionShimmer": mix(tokens.accent, tokens.primaryText, 0.35),
            "remember": tokens.stateNeedsInput,
            // Status.
            "success": tokens.stateWorking,
            "error": tokens.danger,
            "warning": tokens.stateNeedsInput,
            "warningShimmer": mix(tokens.stateNeedsInput, tokens.primaryText, 0.35),
            "merged": tokens.groupHeader,
            // Input box and modes.
            "promptBorder": promptBorder,
            "promptBorderShimmer": tokens.secondaryText,
            "planMode": tokens.stateIdle,
            "autoAccept": tokens.stateNeedsInput,
            "bashBorder": tokens.branch,
            "ide": tokens.stateIdle,
            // Diffs: the state colours washed into the pane.
            "diffAdded": mix(pane, tokens.stateWorking, 0.22),
            "diffRemoved": mix(pane, tokens.danger, 0.22),
            "diffAddedWord": mix(pane, tokens.stateWorking, 0.45),
            "diffRemovedWord": mix(pane, tokens.danger, 0.45),
            "diffAddedDimmed": mix(pane, tokens.stateWorking, 0.10),
            "diffRemovedDimmed": mix(pane, tokens.danger, 0.10),
            // Transcript backgrounds: Loom's surfaces.
            "userMessageBackground": tokens.surface,
            "userMessageBackgroundHover": tokens.surfaceRaised,
            "bashMessageBackgroundColor": tokens.surface,
            "memoryBackgroundColor": tokens.surface,
            "selectionBg": mix(pane, tokens.accent, 0.3),
            // Usage meter and speaker labels.
            "rate_limit_fill": tokens.accent,
            "rate_limit_empty": tokens.cardBorder,
            "briefLabelYou": tokens.stateIdle,
            "briefLabelClaude": tokens.accent,
        ]
    }

    /// The theme file's bytes — deterministic, so an unchanged theme is
    /// recognised and left alone (every write is a reload in every session).
    public static func document(name: String, tokens: ThemeTokens, isLight: Bool) -> Data {
        let theme: [String: Any] = [
            "name": name,
            "base": isLight ? "light" : "dark",
            "overrides": overrides(for: tokens),
        ]
        return (try? JSONSerialization.data(withJSONObject: theme,
                                            options: [.prettyPrinted, .sortedKeys,
                                                      .withoutEscapingSlashes])) ?? Data()
    }

    // MARK: Slugs — the file names, and what `custom:` points at

    /// The live theme of a context: one per project, `loom` without one.
    /// Stable: its content changes, never its name.
    public static func liveSlug(for projectID: ProjectID?) -> String {
        guard let projectID else { return "loom" }
        let hex = projectID.rawValue.uuidString.lowercased().filter(\.isHexDigit)
        return "loom-project-" + String(hex.prefix(8))
    }

    /// A family's variant in the catalog `/theme` lists.
    public static func catalogSlug(family: ThemeFamily, dark: Bool) -> String {
        let ascii = family.slug.filter { $0.isASCII && ($0.isLetter || $0.isNumber) || $0 == "-" }
        let trimmed = ascii.split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return "loom-\(trimmed.isEmpty ? "theme" : trimmed)-\(dark ? "dark" : "light")"
    }

    /// The setting value that selects a slug.
    public static func settingValue(slug: String) -> String { "custom:" + slug }

    /// Whether a file in the themes folder is Loom's — the only ones it ever
    /// rewrites or removes. Anything else there is the user's.
    public static func isOwned(filename: String) -> Bool {
        filename.range(of: #"^loom(-project-[0-9a-f]{8}|-[a-z0-9]+(-[a-z0-9]+)*-(dark|light))?\.json$"#,
                       options: .regularExpression) != nil
    }

    /// Every file Loom wants in the folder, by name: the catalog (each
    /// family, light and dark) and the live themes.
    public static func files(families: [ThemeFamily],
                             live: [(slug: String, name: String, palette: ThemePalette)])
        -> [String: Data] {
        var files: [String: Data] = [:]
        for family in families {
            for dark in [true, false] {
                let palette = family.palette(dark: dark)
                files[catalogSlug(family: family, dark: dark) + ".json"] =
                    document(name: "Loom · " + palette.name, tokens: palette.tokens,
                             isLight: palette.isLight)
            }
        }
        for theme in live {
            files[theme.slug + ".json"] = document(name: theme.name, tokens: theme.palette.tokens,
                                                   isLight: theme.palette.isLight)
        }
        return files
    }

    /// Makes Loom's files in `directory` exactly `files`: writes what changed,
    /// removes what Loom owns and no longer wants. The user's files stay.
    public static func write(_ files: [String: Data], to directory: URL) throws {
        let manager = FileManager.default
        // Nothing to write and no folder: nothing of Loom's to remove either —
        // the sync being off must not create anything in the user's config.
        if files.isEmpty && !manager.fileExists(atPath: directory.path) { return }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, data) in files {
            let url = directory.appendingPathComponent(name)
            if (try? Data(contentsOf: url)) == data { continue }
            try data.write(to: url, options: .atomic)
        }
        let present = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in present where isOwned(filename: name) && files[name] == nil {
            try? manager.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}

// MARK: - Sync: keeping the folder in step with the store

/// Keeps Claude Code's themes folder in step with Loom's themes, when the
/// user opted in. Sessions launched by Loom select their project's live
/// theme; rewriting it recolours them in place.
@MainActor
public final class ClaudeThemeSync {
    /// Off by default: it writes into the user's Claude config.
    public static let enabledKey = "loom.theme.syncClaude"

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    /// Writes the catalog and one live theme per project (plus the global
    /// one), or — when disabled — removes every file Loom put there. Errors
    /// are swallowed: a theme that cannot be written leaves Claude's own.
    public func sync(store: ThemeStore, projects: [(id: ProjectID, name: String)]) {
        guard isEnabled else {
            try? ClaudeThemeExport.write([:], to: directory)
            return
        }
        var live: [(slug: String, name: String, palette: ThemePalette)] = [
            (slug: ClaudeThemeExport.liveSlug(for: nil), name: "Loom", palette: store.palette(for: nil)),
        ]
        for project in projects {
            live.append((slug: ClaudeThemeExport.liveSlug(for: project.id),
                         name: "Loom · " + project.name,
                         palette: store.palette(for: project.id)))
        }
        try? ClaudeThemeExport.write(ClaudeThemeExport.files(families: store.families, live: live),
                                     to: directory)
    }

    /// What a session of this project passes as `theme`; nil when disabled.
    public func settingValue(for projectID: ProjectID?) -> String? {
        guard isEnabled else { return nil }
        return ClaudeThemeExport.settingValue(slug: ClaudeThemeExport.liveSlug(for: projectID))
    }
}
