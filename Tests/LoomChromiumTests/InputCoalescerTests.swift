import Testing
import LoomChromium
import Foundation

// Seam: one move or wheel in flight; while it is, the latest move wins and
// wheel deltas add up; a press or a key flushes what waits first.

@Suite("InputCoalescer — moves and wheels, one in flight")
struct InputCoalescerTests {

    private func move(_ x: Double) -> PanelCDPCommand {
        mouseCommand("mouseMoved", x: x, y: 10)
    }

    private func wheel(_ deltaY: Double, x: Double = 10) -> PanelCDPCommand {
        wheelCommand(x: x, y: 10, deltaX: 0, deltaY: deltaY)
    }

    private let press = mouseCommand("mousePressed", x: 30, y: 10, button: "left", buttons: 1, clickCount: 1)

    @Test("a first move goes at once and is tracked; the next ones wait, the latest wins")
    func dernierMouvement() {
        var coalescer = InputCoalescer()
        let first = coalescer.submit([move(1)])
        #expect(first == InputCoalescer.Output(tracked: move(1)))
        #expect(coalescer.inFlight)
        let second = coalescer.submit([move(2)])
        let third = coalescer.submit([move(3)])
        #expect(second.isEmpty)
        #expect(third.isEmpty)
        #expect(coalescer.pending == [move(3)])
        let next = coalescer.didReceiveReply()
        #expect(next == move(3))
        #expect(coalescer.inFlight)
        let done = coalescer.didReceiveReply()
        #expect(done == nil)
        #expect(!coalescer.inFlight)
    }

    @Test("wheel deltas add up while one is in flight; the point is the latest")
    func sommeDesMolettes() {
        var coalescer = InputCoalescer()
        _ = coalescer.submit([wheel(10)])
        _ = coalescer.submit([wheel(20, x: 11)])
        _ = coalescer.submit([wheel(-5, x: 12)])
        let next = coalescer.didReceiveReply()
        #expect(next == wheel(15, x: 12))
    }

    @Test("a press flushes what waits, in order, then goes itself — untracked, in one write")
    func pressionVide() {
        var coalescer = InputCoalescer()
        _ = coalescer.submit([move(1)])
        _ = coalescer.submit([wheel(10)])
        _ = coalescer.submit([move(2)])
        #expect(coalescer.pending == [wheel(10), move(2)])
        let out = coalescer.submit([move(3), press])
        #expect(out == InputCoalescer.Output(write: [wheel(10), move(2), move(3), press]))
        #expect(coalescer.pending.isEmpty)
        // The tracked move's reply still comes: nothing waits.
        let after = coalescer.didReceiveReply()
        #expect(after == nil)
    }

    @Test("a press with nothing in flight goes as is")
    func pressionSeule() {
        var coalescer = InputCoalescer()
        let out = coalescer.submit([press])
        #expect(out == InputCoalescer.Output(write: [press]))
        #expect(!coalescer.inFlight)
    }

    @Test("order kept across kinds: a move and a wheel wait in the order they last changed")
    func ordreGarde() {
        var coalescer = InputCoalescer()
        _ = coalescer.submit([move(1)])
        _ = coalescer.submit([move(2)])
        _ = coalescer.submit([wheel(10)])
        #expect(coalescer.pending == [move(2), wheel(10)])
        _ = coalescer.submit([move(4)])
        #expect(coalescer.pending == [wheel(10), move(4)])
        let first = coalescer.didReceiveReply()
        let second = coalescer.didReceiveReply()
        let third = coalescer.didReceiveReply()
        #expect(first == wheel(10))
        #expect(second == move(4))
        #expect(third == nil)
    }

    @Test("discardPending drops what waits (the agent acts); reset forgets the request in flight too")
    func abandon() {
        var coalescer = InputCoalescer()
        _ = coalescer.submit([move(1)])
        _ = coalescer.submit([move(2)])
        coalescer.discardPending()
        #expect(coalescer.pending.isEmpty)
        #expect(coalescer.inFlight)
        coalescer.reset()
        #expect(!coalescer.inFlight)
        let fresh = coalescer.submit([move(5)])
        #expect(fresh.tracked == move(5))
    }

    @Test("only moves and wheels coalesce")
    func genres() {
        #expect(InputCoalescer.kind(of: move(1)) == .move)
        #expect(InputCoalescer.kind(of: mouseCommand("mouseMoved", x: 1, y: 1, button: "left", buttons: 1)) == .move)
        #expect(InputCoalescer.kind(of: wheel(1)) == .wheel)
        #expect(InputCoalescer.kind(of: press) == nil)
        #expect(InputCoalescer.kind(of: insertTextCommand("a")) == nil)
        var coalescer = InputCoalescer()
        let empty = coalescer.submit([])
        #expect(empty.isEmpty)
        #expect(!coalescer.inFlight)
    }
}
