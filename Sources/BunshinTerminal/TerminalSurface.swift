import BunshinCore
import Foundation
import Observation

/// Projection MainActor d'un terminal pour la couche vue (design C retenu, ADR-0008).
/// Ne contient AUCUNE référence au moteur : `screen` est une valeur recopiée depuis
/// la queue de session, jamais une fenêtre dessus.
@MainActor
@Observable
public final class TerminalSurface {

    public let terminal: TerminalID

    /// Jamais optionnel, jamais vide : écran vierge à la bonne géométrie avant le
    /// premier attachement, dernier écran connu ensuite. La vue n'a aucun état de
    /// chargement à rendre (transition UIX-03 correcte dès la première frame).
    public private(set) var screen: TerminalScreen
    /// Queue du scrollback (au plus 400 lignes) — le défilement de la vue.
    public private(set) var history: [TerminalLine] = []
    public private(set) var isAttached = false

    private weak var runtime: SessionRuntime?

    init(terminal: TerminalID, geometry: TerminalGeometry, runtime: SessionRuntime) {
        self.terminal = terminal
        self.screen = .blank(geometry)
        self.runtime = runtime
    }

    /// Attache : les frames arrivent tant qu'on ne détache pas. Idempotent.
    public func attach() {
        guard !isAttached else { return }
        isAttached = true
        runtime?.setAttachment(terminal, attached: true)
    }

    /// Détache : plus aucune frame n'est produite pour cette surface ; `screen`
    /// garde le dernier écran connu. Parsing et transcript continuent (TRM-03).
    public func detach() {
        guard isAttached else { return }
        isAttached = false
        runtime?.setAttachment(terminal, attached: false)
    }

    /// Le chemin normal du cycle de vie : `.task { await surface.attached() }`.
    /// Attache à l'entrée, détache à l'annulation — l'oubli est non représentable.
    public func attached() async {
        attach()
        defer { detach() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled {
                    continuation.resume()
                    return
                }
                lifecycleContinuation = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.lifecycleContinuation?.resume()
                self?.lifecycleContinuation = nil
            }
        }
    }

    /// Frappe clavier / message rapide (SES-05) : non bloquant, non jetant, sans vue requise.
    public func send(_ text: String) {
        runtime?.write(text, to: terminal)
    }

    /// TRM-02 : la vue annonce sa grille ; moteur et PTY suivent (SIGWINCH côté agent).
    /// Coalescé côté appel : seule une vraie nouvelle géométrie traverse.
    public func resize(cols: Int, rows: Int) {
        guard cols >= 20, rows >= 4 else { return }
        let geometry = TerminalGeometry(cols: cols, rows: rows)
        guard geometry != lastRequestedGeometry else { return }
        lastRequestedGeometry = geometry
        runtime?.resize(to: geometry)
    }

    private var lastRequestedGeometry: TerminalGeometry?

    func receive(_ screen: TerminalScreen, history: [TerminalLine]) {
        guard isAttached else { return }
        self.screen = screen
        self.history = history
    }

    private var lifecycleContinuation: CheckedContinuation<Void, Never>?
}

extension SessionRuntime {
    /// Projection partagée pour la couche vue. Idempotent : même `TerminalID` →
    /// même instance, que plusieurs vues peuvent observer.
    @MainActor
    public func surface(_ terminal: TerminalID = .primary) -> TerminalSurface {
        if let existing = surfaces[terminal] { return existing }
        let surface = TerminalSurface(terminal: terminal, geometry: launchGeometry, runtime: self)
        surfaces[terminal] = surface
        return surface
    }
}
