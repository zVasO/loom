import LoomCore
import Foundation

/// The two ways a session shows in the Sessions tab (ADR-0023): its terminal,
/// where claude runs, or the conversation of its native session, read from
/// claude's own file.
enum SessionViewMode: String {
    case terminal, chat
}

// The mode lives in the model, keyed by session: the detail view is rebuilt
// at every tab switch, and would forget it.

extension AppModel {

    /// The last mode chosen, for whatever session: one never toggled opens in it.
    static let sessionViewModeKey = "loom.session.viewMode"

    func viewMode(for id: SessionID) -> SessionViewMode {
        // A shell has no conversation: its terminal is all there is.
        if sessions.first(where: { $0.id == id })?.isShell == true { return .terminal }
        if let chosen = sessionViewModes[id] { return chosen }
        let stored = UserDefaults.standard.string(forKey: Self.sessionViewModeKey) ?? ""
        return SessionViewMode(rawValue: stored) ?? .terminal
    }

    /// The breadcrumb's toggle and the chat view's "Open terminal".
    func setViewMode(_ mode: SessionViewMode, for id: SessionID) {
        guard sessions.first(where: { $0.id == id })?.isShell != true else { return }
        if sessionViewModes[id] != mode { sessionViewModes[id] = mode }
        UserDefaults.standard.set(mode.rawValue, forKey: Self.sessionViewModeKey)
    }

    /// ⌘⇧M.
    func toggleViewMode(for id: SessionID) {
        setViewMode(viewMode(for: id) == .chat ? .terminal : .chat, for: id)
    }

    /// An archived session forgets its mode.
    func forgetViewMode(_ id: SessionID) {
        sessionViewModes.removeValue(forKey: id)
    }
}
