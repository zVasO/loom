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
    public private(set) var isAttached = false

    private weak var runtime: SessionRuntime?

    init(terminal: TerminalID, geometry: TerminalGeometry, runtime: SessionRuntime) {
        self.terminal = terminal
        self.screen = .blank(geometry)
        self.runtime = runtime
    }

    /// Attach: frames keep arriving until detached. Idempotent.
    public func attach() {
        guard !isAttached else { return }
        isAttached = true
        runtime?.setAttachment(terminal, attached: true)
    }

    /// Detach: no more frames are produced for this surface; `screen` keeps the
    /// last known screen. Parsing and transcript carry on (TRM-03).
    public func detach() {
        guard isAttached else { return }
        isAttached = false
        runtime?.setAttachment(terminal, attached: false)
    }

    /// The normal lifecycle path: `.task { await surface.attached() }`.
    /// Attaches on entry, detaches on cancellation — forgetting is unrepresentable.
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

    /// Keystroke / quick message (SES-05): non-blocking, non-throwing, no view required.
    public func send(_ text: String) {
        runtime?.write(text, to: terminal)
    }

    /// TRM-02: the view announces its grid; engine and PTY follow (SIGWINCH on the
    /// agent side). Coalesced at the call site: only a genuinely new geometry gets through.
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
