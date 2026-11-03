import Testing
import Foundation
import LoomChromium

// Seam: when the screencast goes lossless and back (ADR-0016) — JPEG while
// the page moves, PNG once it holds still.
@Suite("StillFrameRefiner — the page lossless once it holds still")
struct StillFrameRefinerTests {

    @Test("a frame's format is read from its bytes")
    func format() {
        #expect(StillFrameRefiner.Format.of(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])) == .png)
        #expect(StillFrameRefiner.Format.of(Data([0xFF, 0xD8, 0xFF, 0xE0])) == .jpeg)
        #expect(StillFrameRefiner.Format.of(Data()) == .jpeg)
    }

    @Test("still for a moment: PNG; the next change: back to JPEG")
    func cycle() {
        var refiner = StillFrameRefiner()
        guard case .wait(let seconds, let token) = refiner.frame(.jpeg, at: 0) else {
            Issue.record("a JPEG frame starts the wait")
            return
        }
        #expect(seconds == StillFrameRefiner.stillDelay)
        #expect(refiner.still(token: token) == .restart(.png))
        #expect(refiner.format == .png)
        #expect(refiner.still(token: token) == .none, "asked once")
        #expect(refiner.frame(.jpeg, at: 0.21) == .none, "a JPEG still in flight changes nothing")
        #expect(refiner.frame(.png, at: 0.25) == .none, "the restart's frame: the page lossless")
        #expect(refiner.frame(.png, at: 5) == .restart(.jpeg), "the page changed")
        #expect(refiner.format == .jpeg)
        #expect(refiner.delay == StillFrameRefiner.stillDelay, "a long still run keeps the short wait")
    }

    @Test("a newer frame voids the wait")
    func newerFrame() {
        var refiner = StillFrameRefiner()
        guard case .wait(_, let first) = refiner.frame(.jpeg, at: 0),
              case .wait(_, let second) = refiner.frame(.jpeg, at: 0.016) else {
            Issue.record("JPEG frames wait")
            return
        }
        #expect(refiner.still(token: first) == .none)
        #expect(refiner.still(token: second) == .restart(.png))
    }

    @Test("a page that keeps changing (a caret blinking) is waited on longer, up to a cap")
    func backoff() {
        var refiner = StillFrameRefiner()
        var now = 0.0
        for _ in 0..<8 {
            guard case .wait(_, let token) = refiner.frame(.jpeg, at: now) else {
                Issue.record("JPEG frames wait")
                return
            }
            _ = refiner.still(token: token)
            _ = refiner.frame(.png, at: now + 0.25)
            now += 0.5
            #expect(refiner.frame(.png, at: now) == .restart(.jpeg))
        }
        #expect(refiner.delay == StillFrameRefiner.maxDelay)
    }

    @Test("a restart for another tab or size voids the wait and goes back to JPEG")
    func restarted() {
        var refiner = StillFrameRefiner()
        guard case .wait(_, let token) = refiner.frame(.jpeg, at: 0) else {
            Issue.record("a JPEG frame starts the wait")
            return
        }
        refiner.restarted()
        #expect(refiner.still(token: token) == .none)
        #expect(refiner.format == .jpeg)
    }
}
