import LoomCore
import Foundation

/// Format de thème (THM-04) : JSON versionné, deux espaces OPTIONNELS — un thème
/// partiel fusionne avec le parent (le sombre par défaut) à la résolution.
public struct Theme: Codable, Sendable, Equatable {

    public enum Appearance: String, Codable, Sendable {
        case dark, light
    }

    public struct UISpace: Codable, Sendable, Equatable {
        public var background: ThemeColor?
        public var surface: ThemeColor?
        public var accent: ThemeColor?
        public var primaryText: ThemeColor?
        public var secondaryText: ThemeColor?
        /// Couleurs sémantiques des états — les thèmes ajustent la teinte, jamais le
        /// sens (THM-08) : la clé est l'état, pas une couleur libre.
        public var stateColors: [SessionState: ThemeColor]?
    }

    public struct TerminalSpace: Codable, Sendable, Equatable {
        public var background: ThemeColor
        public var foreground: ThemeColor
        public var cursor: ThemeColor
        public var selection: ThemeColor
        /// 16 couleurs : ANSI 0–7 + brights 8–15.
        public var ansi: [ThemeColor]
    }

    public var schemaVersion: Int
    public var name: String
    public var appearance: Appearance
    public var ui: UISpace?
    public var terminal: TerminalSpace?
}

/// Couleur hex `#RRGGBB` — valeur comparable, sérialisable, indépendante de SwiftUI.
public struct ThemeColor: Codable, Sendable, Equatable, Hashable {
    public let hex: String

    public init(_ hex: String) {
        self.hex = hex.uppercased()
    }

    public init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }

    public var components: (red: Double, green: Double, blue: Double)? {
        var value = hex
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let number = UInt32(value, radix: 16) else { return nil }
        return (Double((number >> 16) & 0xFF) / 255,
                Double((number >> 8) & 0xFF) / 255,
                Double(number & 0xFF) / 255)
    }
}

// MARK: - Résolution (THM-08 : un seul résolveur, aucune couleur en dur dans les vues)

public enum ThemeOverride: Sendable, Equatable {
    /// THM-03 : le chemin rapide — juste la couleur signature du projet.
    case accent(ThemeColor)
    /// THM-02 : un thème entier pour le projet.
    case theme(Theme)
}

public struct ResolvedTheme: Sendable, Equatable {
    public struct UISpace: Sendable, Equatable {
        public var background: ThemeColor
        public var surface: ThemeColor
        public var accent: ThemeColor
        public var primaryText: ThemeColor
        public var secondaryText: ThemeColor
        public var stateColors: [SessionState: ThemeColor]
    }
    public var ui: UISpace
    public var terminal: Theme.TerminalSpace
}

public enum ThemeResolver {

    /// Cascade : thème de l'app → override projet ; chaque espace manquant est comblé
    /// par le parent, en dernier ressort par le sombre par défaut. Jamais de trou.
    public static func resolve(app: Theme, projectOverride: ThemeOverride?) -> ResolvedTheme {
        var effective = app
        var accentOverride: ThemeColor?
        switch projectOverride {
        case .theme(let projectTheme):
            effective = projectTheme
        case .accent(let accent):
            accentOverride = accent
        case nil:
            break
        }

        let fallback = Theme.builtinDark
        let ui = effective.ui
        let fallbackUI = fallback.ui!
        var resolvedUI = ResolvedTheme.UISpace(
            background: ui?.background ?? fallbackUI.background!,
            surface: ui?.surface ?? fallbackUI.surface!,
            accent: ui?.accent ?? fallbackUI.accent!,
            primaryText: ui?.primaryText ?? fallbackUI.primaryText!,
            secondaryText: ui?.secondaryText ?? fallbackUI.secondaryText!,
            stateColors: ui?.stateColors ?? fallbackUI.stateColors!)
        if let accentOverride { resolvedUI.accent = accentOverride }

        return ResolvedTheme(ui: resolvedUI,
                             terminal: effective.terminal ?? fallback.terminal!)
    }
}

// MARK: - Thèmes intégrés (THM-01 : ≥ 4 au lancement)

extension Theme {

    public static let builtins: [Theme] = [.builtinDark, .builtinWarmDark, .builtinLight, .builtinHighContrast]

    static func semanticStates(working: String, needsInput: String, idle: String,
                               completed: String, failed: String) -> [SessionState: ThemeColor] {
        [.working: ThemeColor(working), .needsInput: ThemeColor(needsInput),
         .idle: ThemeColor(idle), .starting: ThemeColor(idle),
         .completed: ThemeColor(completed), .archived: ThemeColor(completed),
         .draft: ThemeColor(completed),
         .failed: ThemeColor(failed), .interrupted: ThemeColor(failed)]
    }

    public static let builtinDark = Theme(
        schemaVersion: 1, name: "Sombre", appearance: .dark,
        ui: UISpace(background: ThemeColor("#0B0B0F"), surface: ThemeColor("#17171C"),
                    accent: ThemeColor("#E8833A"), primaryText: ThemeColor("#EBEBF0"),
                    secondaryText: ThemeColor("#8C8C99"),
                    stateColors: semanticStates(working: "#4CC38A", needsInput: "#E5B455",
                                                idle: "#6AA2E8", completed: "#8F8FA3",
                                                failed: "#E5646C")),
        terminal: TerminalSpace(background: ThemeColor("#0B0B0F"), foreground: ThemeColor("#EBEBF0"),
                                cursor: ThemeColor("#E8833A"), selection: ThemeColor("#33415C"),
                                ansi: standardANSI))

    public static let builtinWarmDark = Theme(
        schemaVersion: 1, name: "Sombre chaud", appearance: .dark,
        ui: UISpace(background: ThemeColor("#141110"), surface: ThemeColor("#1F1A18"),
                    accent: ThemeColor("#E8A03A"), primaryText: ThemeColor("#F0EAE4"),
                    secondaryText: ThemeColor("#9C918A"),
                    stateColors: semanticStates(working: "#7FBF6A", needsInput: "#E8A03A",
                                                idle: "#8AA0C8", completed: "#9C918A",
                                                failed: "#D96459")),
        terminal: TerminalSpace(background: ThemeColor("#141110"), foreground: ThemeColor("#F0EAE4"),
                                cursor: ThemeColor("#E8A03A"), selection: ThemeColor("#4A3B2E"),
                                ansi: standardANSI))

    public static let builtinLight = Theme(
        schemaVersion: 1, name: "Clair", appearance: .light,
        ui: UISpace(background: ThemeColor("#F5F5F7"), surface: ThemeColor("#FFFFFF"),
                    accent: ThemeColor("#D96C1E"), primaryText: ThemeColor("#1C1C21"),
                    secondaryText: ThemeColor("#6E6E7A"),
                    stateColors: semanticStates(working: "#2E8B57", needsInput: "#B8860B",
                                                idle: "#3B6BB5", completed: "#6E6E7A",
                                                failed: "#C0392B")),
        terminal: TerminalSpace(background: ThemeColor("#FFFFFF"), foreground: ThemeColor("#1C1C21"),
                                cursor: ThemeColor("#D96C1E"), selection: ThemeColor("#C9DDF5"),
                                ansi: standardANSI))

    public static let builtinHighContrast = Theme(
        schemaVersion: 1, name: "Contraste élevé", appearance: .dark,
        ui: UISpace(background: ThemeColor("#000000"), surface: ThemeColor("#101010"),
                    accent: ThemeColor("#FFB000"), primaryText: ThemeColor("#FFFFFF"),
                    secondaryText: ThemeColor("#C8C8C8"),
                    stateColors: semanticStates(working: "#00E676", needsInput: "#FFD600",
                                                idle: "#40C4FF", completed: "#BDBDBD",
                                                failed: "#FF5252")),
        terminal: TerminalSpace(background: ThemeColor("#000000"), foreground: ThemeColor("#FFFFFF"),
                                cursor: ThemeColor("#FFB000"), selection: ThemeColor("#404040"),
                                ansi: standardANSI))

    static let standardANSI: [ThemeColor] = [
        "#1A1A1A", "#CC4040", "#4DBF66", "#D9BF4D", "#598CE6", "#BF73D9", "#4DBFCC", "#D9D9D9",
        "#666666", "#F26666", "#73E68C", "#F2D973", "#80B3FF", "#D999F2", "#73E6F2", "#FFFFFF",
    ].map(ThemeColor.init)
}
