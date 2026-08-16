import AppKit
import SwiftUI

/// SES-05bis : la saisie se fait DANS le champ de l'agent, pas dans une barre à
/// nous — chaque frappe est traduite en octets terminal et envoyée au PTY.
/// Traduction pure, séparée de la vue : c'est elle qui porte les tests.
public enum KeyTranslator {

    /// Touches spéciales identifiées par code virtuel matériel (indépendant de la
    /// disposition clavier). `nil` = touche ordinaire, à composer par la vue.
    public static func special(keyCode: UInt16, option: Bool) -> String? {
        switch keyCode {
        case 36, 76: return option ? "\u{1b}\r" : "\r"   // Entrée (+ pavé numérique)
        case 48: return "\t"
        case 51: return "\u{7f}"                          // effacement arrière → DEL
        case 53: return "\u{1b}"
        case 117: return "\u{1b}[3~"                      // suppression avant
        case 115: return "\u{1b}[H"
        case 119: return "\u{1b}[F"
        case 116: return "\u{1b}[5~"
        case 121: return "\u{1b}[6~"
        case 123: return "\u{1b}[D"
        case 124: return "\u{1b}[C"
        case 125: return "\u{1b}[B"
        case 126: return "\u{1b}[A"
        default: return nil
        }
    }

    /// Traduction complète d'une frappe : touche spéciale d'abord, sinon le texte
    /// produit par la disposition réelle (AZERTY, accents…). `nil` = rien à envoyer.
    public static func bytes(keyCode: UInt16, characters: String, option: Bool) -> String? {
        if let special = special(keyCode: keyCode, option: option) { return special }
        return characters.isEmpty ? nil : characters
    }
}

/// Zone invisible sous le terminal : premier répondant, elle pousse chaque frappe
/// vers le PTY — la saisie vit dans le champ de l'agent. Les touches ordinaires
/// passent par `interpretKeyEvents` pour composer les touches mortes (ê, î…),
/// les raccourcis ⌘ restent au système, ⌘V colle dans le champ de l'agent.
public struct KeyCaptureView: NSViewRepresentable {
    /// Incrémenté par la vue hôte quand l'utilisateur clique le terminal :
    /// signal explicite de reprise du focus, même si un TextField l'avait.
    let focusTick: Int
    let onText: (String) -> Void

    public init(focusTick: Int = 0, onText: @escaping (String) -> Void) {
        self.focusTick = focusTick
        self.onText = onText
    }

    public func makeNSView(context: Context) -> CaptureNSView {
        let view = CaptureNSView()
        view.onText = onText
        return view
    }

    public func updateNSView(_ view: CaptureNSView, context: Context) {
        view.onText = onText
        guard let window = view.window else { return }
        let clicked = view.lastFocusTick != focusTick
        view.lastFocusTick = focusTick
        // Reprise du focus : sur clic explicite, ou si plus rien n'est focalisé —
        // jamais en le volant à un champ de texte actif (renommage, palette…).
        if clicked || window.firstResponder === window {
            DispatchQueue.main.async { [weak view] in
                view.map { $0.window?.makeFirstResponder($0) }
            }
        }
    }

    public final class CaptureNSView: NSView {
        var onText: ((String) -> Void)?
        var lastFocusTick = 0

        public override var acceptsFirstResponder: Bool { true }

        public override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }

        public override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
        }

        public override func keyDown(with event: NSEvent) {
            guard !event.modifierFlags.contains(.command) else {
                super.keyDown(with: event)
                return
            }
            if let special = KeyTranslator.special(keyCode: event.keyCode,
                                                   option: event.modifierFlags.contains(.option)) {
                onText?(special)
                return
            }
            // Ctrl+lettre : le caractère de contrôle est déjà dans characters (⌃C → ETX).
            if event.modifierFlags.contains(.control) {
                if let text = event.characters, !text.isEmpty { onText?(text) }
                return
            }
            // Composition système (touches mortes, IME) → insertText.
            interpretKeyEvents([event])
        }

        public override func insertText(_ insertString: Any) {
            if let text = insertString as? String {
                onText?(text)
            } else if let attributed = insertString as? NSAttributedString {
                onText?(attributed.string)
            }
        }

        public override func doCommand(by selector: Selector) {
            // Les sélecteurs d'édition sont déjà couverts par les touches spéciales ;
            // on absorbe le reste sans faire sonner le bip système.
        }

        public override func performKeyEquivalent(with event: NSEvent) -> Bool {
            // ⌘V : collage direct dans le champ de l'agent.
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers == "v",
               let text = NSPasteboard.general.string(forType: .string) {
                onText?(text)
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
    }
}
