import Foundation

// Pipelining of the panel's input (panel design §2, Pipelining). Presses,
// releases, keys and text are written in order and never awaited one by one
// — a confirm() a press opens cannot stall the panel. Moves and wheels, which
// a trackpad sends at 60 Hz or more, keep at most ONE request in flight:
// while it is, the latest move wins and wheel deltas add up. A press or a
// key first flushes what waits, so the page sees everything in order.
//
// The pump drives it:
//
//     let out = coalescer.submit(commands)
//     post(batch: out.write)                                   // untracked, in order
//     if let next = out.tracked { post(next) { reply in        // reply or failure
//         if let next = coalescer.didReceiveReply() { post(next) { … } }   // same callback
//     } }

public struct InputCoalescer: Equatable, Sendable {

    public enum Kind: Equatable, Sendable {
        case move
        case wheel
    }

    /// What to send for one submission: `write` first, in one write and in
    /// order; then `tracked`, the one request whose reply (or failure) must
    /// call `didReceiveReply`.
    public struct Output: Equatable, Sendable {
        public var write: [PanelCDPCommand]
        public var tracked: PanelCDPCommand?

        public init(write: [PanelCDPCommand] = [], tracked: PanelCDPCommand? = nil) {
            self.write = write
            self.tracked = tracked
        }

        public var isEmpty: Bool {
            write.isEmpty && tracked == nil
        }
    }

    /// A move or a wheel is on the wire, its reply not yet in.
    public private(set) var inFlight = false
    /// What waits for that reply: at most one move and one wheel, in the
    /// order they last changed.
    public private(set) var pending: [PanelCDPCommand] = []

    public init() {}

    /// A move (`mouseMoved`, drags included) or a wheel; nil for anything
    /// that must keep its place.
    public static func kind(of command: PanelCDPCommand) -> Kind? {
        guard command.method == PanelCDPCommand.dispatchMouseEvent else { return nil }
        switch command.type ?? "" {
        case "mouseMoved": return .move
        case "mouseWheel": return .wheel
        default: return nil
        }
    }

    /// Commands one user event produced. Moves and wheels alone wait their
    /// turn (merged with what waits); anything else goes now, after what
    /// waits.
    public mutating func submit(_ commands: [PanelCDPCommand]) -> Output {
        guard !commands.isEmpty else { return Output() }
        if commands.allSatisfy({ Self.kind(of: $0) != nil }) {
            for command in commands {
                enqueue(command)
            }
            guard !inFlight, !pending.isEmpty else { return Output() }
            inFlight = true
            return Output(tracked: pending.removeFirst())
        }
        let write = pending + commands
        pending = []
        return Output(write: write)
    }

    /// The tracked request's reply, or its failure, arrived: the next one to
    /// send and track, or nil when nothing waits.
    public mutating func didReceiveReply() -> PanelCDPCommand? {
        inFlight = false
        guard !pending.isEmpty else { return nil }
        inFlight = true
        return pending.removeFirst()
    }

    /// The agent takes the page: the user's waiting moves and wheels are
    /// stale. The request in flight still gets its reply.
    public mutating func discardPending() {
        pending = []
    }

    /// The page went (tab switch, relaunch): no reply will come.
    public mutating func reset() {
        pending = []
        inFlight = false
    }

    private mutating func enqueue(_ command: PanelCDPCommand) {
        guard let kind = Self.kind(of: command) else { return }
        var merged = command
        if let index = pending.firstIndex(where: { Self.kind(of: $0) == kind }) {
            if kind == .wheel {
                merged = Self.sum(pending[index], command)
            }
            pending.remove(at: index)
        }
        pending.append(merged)
    }

    /// Two wheels as one: the deltas add up; the point and the modifiers
    /// are the latest.
    static func sum(_ earlier: PanelCDPCommand, _ later: PanelCDPCommand) -> PanelCDPCommand {
        var merged = later
        for key in ["deltaX", "deltaY"] {
            let total = (earlier.params[key]?.doubleValue ?? 0) + (later.params[key]?.doubleValue ?? 0)
            merged.params[key] = .number(total)
        }
        return merged
    }
}
