import BunshinCore
import BunshinTerminal
import SwiftUI

/// Thème sombre par défaut du §7 — le système de thèmes complet (THM-01→09,
/// cascade projet, import iTerm/Ghostty) viendra le remplacer ; d'ici là, une
/// seule source de couleurs, aucune couleur en dur dans les vues.
public enum DefaultTheme {

    public static let background = Color(red: 0.043, green: 0.043, blue: 0.059)   // ≈ #0B0B0F
    public static let surface = Color(red: 0.09, green: 0.09, blue: 0.11)
    public static let accent = Color.orange
    public static let primaryText = Color.white.opacity(0.92)
    public static let secondaryText = Color.white.opacity(0.55)

    /// Sémantique invariante (THM-08) : un thème ajuste la teinte, jamais le sens.
    public static func badgeColor(for state: SessionState) -> Color {
        switch state {
        case .working: .green
        case .needsInput: Color(red: 0.95, green: 0.7, blue: 0.2)   // ambre
        case .idle, .starting: .blue
        case .completed, .archived, .draft: .gray
        case .failed, .interrupted: .red
        }
    }

    public static func label(for state: SessionState) -> String {
        switch state {
        case .draft: "brouillon"
        case .starting: "démarrage"
        case .working: "travaille"
        case .needsInput: "attend une réponse"
        case .idle: "inactif"
        case .completed: "terminé"
        case .failed: "échoué"
        case .interrupted: "interrompu"
        case .archived: "archivé"
        }
    }

    /// Palette ANSI 16 couleurs (espace *Terminal* du thème, THM-04).
    public static func terminalColor(_ color: TerminalColor, isBackground: Bool) -> Color {
        switch color {
        case .default:
            return isBackground ? .clear : primaryText
        case .rgb(let red, let green, let blue):
            return Color(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
        case .ansi(let code):
            return ansiPalette[Int(code) % ansiPalette.count]
        }
    }

    static let ansiPalette: [Color] = [
        Color(white: 0.1), Color(red: 0.8, green: 0.25, blue: 0.25),
        Color(red: 0.3, green: 0.75, blue: 0.4), Color(red: 0.85, green: 0.75, blue: 0.3),
        Color(red: 0.35, green: 0.55, blue: 0.9), Color(red: 0.75, green: 0.45, blue: 0.85),
        Color(red: 0.3, green: 0.75, blue: 0.8), Color(white: 0.85),
        Color(white: 0.4), Color(red: 0.95, green: 0.4, blue: 0.4),
        Color(red: 0.45, green: 0.9, blue: 0.55), Color(red: 0.95, green: 0.85, blue: 0.45),
        Color(red: 0.5, green: 0.7, blue: 1.0), Color(red: 0.85, green: 0.6, blue: 0.95),
        Color(red: 0.45, green: 0.9, blue: 0.95), .white,
    ]
}
