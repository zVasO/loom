import LoomCore
import Foundation
import Observation

/// MainActor projection of a terminal for the view layer (design C selected, ADR-0008).
/// Holds NO reference to the engine: `screen` is a value copied over from the
/// session queue, never a window onto it.
@MainActor
@Observable
public final class TerminalSurface {

    public let terminal: TerminalID

    /// Never optional, never empty: a blank screen at the right geometry before the
    /// first attachment, the last known screen afterwards. The view has no loading
    /// state to render (UIX-03 transition correct from the very first frame).
    public private(set) var screen: TerminalScreen
    /// Scrollback tail (at most 400 lines) — what the view scrolls through.
    public private(set) var history: [TerminalLine] = []
    /// Absolute scrollback index of history[0]: stable identity for the view diff.
    public private(set) var historyBase = 0
    /// Somebody watches: frames flow. Per WATCHER, not per surface — a pane
    /// and a Mission Control card of the same session share this surface,
    /// and at a tab switch the newcomer attaches in the same commit that
    /// cancels the other; a single flag left the survivor detached, frozen
    /// on its last screen. The last to leave detaches.
    public var isAttached: Bool { !watchers.isEmpty }

    private struct Watcher {
        var cadence: FrameCadence
        var continuation: CheckedContinuation<Void, Never>?
    }
    private var watchers: [UUID: Watcher] = [:]

    /// The fastest cadence any watcher asked for; nil when nobody watches.
    private var watchedCadence: FrameCadence? {
        var fastest: Duration?
        for watcher in watchers.values {
            switch watcher.cadence {
            case .live: return .live
            case .preview(let interval): fastest = min(fastest ?? interval, interval)
            }
        }
        return fastest.map { .preview($0) }
    }
    /// The input modes the program negotiated (mouse, bracketed paste, cursor
    /// keys, kitty keyboard flags) — what the key capture must honour.
    public private(set) var modes = TerminalModes.none
    /// The program has written at least one byte. `screen.revision` cannot
    /// tell: a resize bumps it on a blank screen, and the view's first fit
    /// happens before the agent has booted.
    public private(set) var hasOutput = false
    /// The agent tracks the mouse: the wheel belongs to IT, not to our ScrollView.
    public var mouseReporting: Bool { modes.mouseReporting }

    private weak var runtime: SessionRuntime?

    init(terminal: TerminalID, geometry: TerminalGeometry, runtime: SessionRuntime) {
        self.terminal = terminal
        self.screen = .blank(geometry)
        self.runtime = runtime
    }

    /// Attach one watcher: frames keep arriving until IT detaches, at
    /// `cadence` (the fastest of all watchers wins). Returns its token.
    @discardableResult
    public func attach(cadence: FrameCadence = .live) -> UUID {
        let token = UUID()
        watchers[token] = Watcher(cadence: cadence, continuation: nil)
        runtime?.setAttachment(terminal, cadence: watchedCadence)
        return token
    }

    /// Detach one watcher. Once the last is gone no more frames are produced
    /// for this surface; `screen` keeps the last known screen. Parsing and
    /// transcript carry on (TRM-03).
    public func detach(_ token: UUID) {
        guard watchers.removeValue(forKey: token) != nil else { return }
        runtime?.setAttachment(terminal, cadence: watchedCadence)
    }

    /// The normal lifecycle path: `.task { await surface.attached() }`.
    /// Attaches on entry, detaches on cancellation — forgetting is unrepresentable.
    public func attached(cadence: FrameCadence = .live) async {
        let token = attach(cadence: cadence)
        defer { detach(token) }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled {
                    continuation.resume()
                    return
                }
                watchers[token]?.continuation = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, let continuation = self.watchers[token]?.continuation else { return }
                self.watchers[token]?.continuation = nil
                continuation.resume()
            }
        }
    }

    /// Keystroke / quick message (SES-05): non-blocking, non-throwing, no view required.
    public func send(_ text: String) {
        runtime?.write(text, to: terminal)
    }

    /// One wheel notch at the cell under the pointer (0-based). Only a tracking
    /// agent hears it; for everyone else the view scrolls the scrollback itself.
    public func sendWheel(_ direction: WheelDirection, atCol col: Int, row: Int) {
        runtime?.sendWheel(direction, atCol: col, row: row)
    }

    /// One click at the cell under the pointer (0-based). Only a tracking agent
    /// hears it; for everyone else a click is nothing but a selection.
    public func sendClick(atCol col: Int, row: Int) {
        runtime?.sendClick(atCol: col, row: row)
    }

    /// The pane gained or lost keyboard focus (DECSET 1004 reports it to a
    /// program that asked). Idempotent on the wire: the emulator dedupes.
    public func setFocus(_ focused: Bool) {
        runtime?.setFocus(focused)
    }

    /// TRM-02: the view announces its grid; engine and PTY follow (SIGWINCH on the
    /// agent side). Deduplicated by the runtime against the grid it actually
    /// applied — a memory kept here could disagree with it, and once did.
    /// Floored at `TerminalGeometry.minimum`: a smaller grid is refused, not clamped.
    public func resize(cols: Int, rows: Int) {
        guard cols >= TerminalGeometry.minimum.cols, rows >= TerminalGeometry.minimum.rows else { return }
        runtime?.resize(to: TerminalGeometry(cols: cols, rows: rows))
    }

    /// Frames that reached this surface — what a test counts to prove that a
    /// frame carrying no visible change never got here.
    private(set) var framesReceived = 0

    func receive(_ screen: TerminalScreen, history: [TerminalLine], base: Int = 0,
                 modes: TerminalModes = .none, hasOutput: Bool = true) {
        guard isAttached else { return }
        framesReceived += 1
        // @Observable notifies on assignment, not on change: only what moved
        // is assigned. The history shares its buffers with the engine's tail
        // cache, so an unchanged tail compares by identity.
        if self.screen.revision != screen.revision || self.screen.cursor != screen.cursor
            || self.screen.geometry != screen.geometry || self.screen.lines.count != screen.lines.count {
            self.screen = screen
        }
        if self.history != history { self.history = history }
        if self.historyBase != base { self.historyBase = base }
        if self.modes != modes { self.modes = modes }
        if self.hasOutput != hasOutput { self.hasOutput = hasOutput }
    }
}

extension SessionRuntime {
    /// Shared projection for the view layer. Idempotent: same `TerminalID` →
    /// same instance, observable by multiple views.
    @MainActor
    public func surface(_ terminal: TerminalID = .primary) -> TerminalSurface {
        if let existing = surfaces[terminal] { return existing }
        let surface = TerminalSurface(terminal: terminal, geometry: launchGeometry, runtime: self)
        surfaces[terminal] = surface
        return surface
    }
}
