import Testing
import Foundation
import LoomCore

// The sidebar order: the cards the user dragged into place keep it, the
// others sit on top, newest creation first — nothing depends on which
// sessions are live, since a restart makes them all dormant.

@Suite("SessionOrder — the user's order of the session cards")
struct SessionOrderTests {

    private struct Card: Equatable {
        let id: SessionID
        let createdAt: Date
    }

    private let a = SessionID(), b = SessionID(), c = SessionID(), d = SessionID()

    /// a oldest … d newest.
    private func card(_ id: SessionID) -> Card {
        let age: [SessionID: TimeInterval] = [a: 1, b: 2, c: 3, d: 4]
        return Card(id: id, createdAt: Date(timeIntervalSince1970: age[id] ?? 0))
    }

    private func order(_ ids: [SessionID], in sessionOrder: SessionOrder) -> [SessionID] {
        sessionOrder.sorted(ids.map(card), id: \.id, createdAt: \.createdAt).map(\.id)
    }

    @Test("never placed: newest first, whatever the input order (a restart swaps live and dormant)")
    func sansRangStableAuRedemarrage() {
        let none = SessionOrder()
        #expect(order([a, b, c], in: none) == [c, b, a], "live first, launch order")
        #expect(order([c, b, a], in: none) == [c, b, a], "dormant first, newest first — same result")
        #expect(order([b, c, a], in: none) == [c, b, a], "one restored at launch, the rest dormant")
    }

    @Test("a move within the group lands on the target's place, both ways")
    func deplacement() {
        var sessionOrder = SessionOrder()
        let up = sessionOrder.move(a, onto: c, within: [c, b, a])
        #expect(up)
        #expect(order([a, b, c], in: sessionOrder) == [a, c, b], "dragged up: before the target")

        let down = sessionOrder.move(a, onto: b, within: [a, c, b])
        #expect(down)
        #expect(order([a, b, c], in: sessionOrder) == [c, b, a], "dragged down: after the target")
    }

    @Test("a session never placed goes on top of the placed ones, and keeps its place once dragged")
    func nouveauEnHaut() {
        var sessionOrder = SessionOrder()
        sessionOrder.move(a, onto: b, within: [b, a])          // the user put a above b
        #expect(order([a, b, d], in: sessionOrder) == [d, a, b], "d is new: on top")
        #expect(order([d, b, a], in: sessionOrder) == [d, a, b], "and the same after a restart")

        sessionOrder.move(d, onto: b, within: [d, a, b])       // then dragged d to the bottom
        #expect(order([a, b, d], in: sessionOrder) == [a, b, d])
    }

    @Test("moving in one group leaves the other groups' ranks alone")
    func groupesIndependants() {
        var sessionOrder = SessionOrder()
        sessionOrder.move(a, onto: b, within: [b, a])     // group 1: a, b
        sessionOrder.move(c, onto: d, within: [d, c])     // group 2: c, d
        #expect(order([a, b], in: sessionOrder) == [a, b])
        #expect(order([c, d], in: sessionOrder) == [c, d])
    }

    @Test("a card outside the group, or onto itself, moves nothing")
    func deplacementRefuse() {
        var sessionOrder = SessionOrder()
        let outside = sessionOrder.move(a, onto: c, within: [a, b])
        let ontoItself = sessionOrder.move(a, onto: a, within: [a, b])
        #expect(!outside)
        #expect(!ontoItself)
        #expect(sessionOrder.ids.isEmpty)
    }

    @Test("sessions that no longer exist are forgotten")
    func nettoyage() {
        var sessionOrder = SessionOrder(ids: [a, b, c])
        sessionOrder.prune(keeping: [a, c])
        #expect(sessionOrder.ids == [a, c])
    }
}
