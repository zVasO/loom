import Testing
import Foundation
import LoomCore

// The sidebar order the user drags into place: ranked sessions are permuted
// among their own slots, the others stay where their natural order puts them.

@Suite("SessionOrder — the user's order of the session cards")
struct SessionOrderTests {

    private let a = SessionID(), b = SessionID(), c = SessionID(), d = SessionID()

    @Test("without any rank, the natural order is kept")
    func sansRang() {
        #expect(SessionOrder().sorted([a, b, c], id: { $0 }) == [a, b, c])
    }

    @Test("a move within the group lands on the target's place, both ways")
    func deplacement() {
        var order = SessionOrder()
        let up = order.move(c, onto: a, within: [a, b, c])
        #expect(up)
        #expect(order.sorted([a, b, c], id: { $0 }) == [c, a, b], "dragged up: before the target")

        let down = order.move(c, onto: b, within: [c, a, b])
        #expect(down)
        #expect(order.sorted([a, b, c], id: { $0 }) == [a, b, c], "dragged down: after the target")
    }

    @Test("an unranked session keeps its natural slot among the ranked ones")
    func nouveauGardeSaPlace() {
        var order = SessionOrder()
        order.move(b, onto: a, within: [a, b])
        // d is new: launched last, it sits where the natural order puts it.
        #expect(order.sorted([a, b, d], id: { $0 }) == [b, a, d])
        #expect(order.sorted([d, a, b], id: { $0 }) == [d, b, a])
    }

    @Test("moving in one group leaves the other groups' ranks alone")
    func groupesIndependants() {
        var order = SessionOrder()
        order.move(b, onto: a, within: [a, b])       // group 1: b, a
        order.move(d, onto: c, within: [c, d])       // group 2: d, c
        #expect(order.sorted([a, b], id: { $0 }) == [b, a])
        #expect(order.sorted([c, d], id: { $0 }) == [d, c])
    }

    @Test("a card outside the group, or onto itself, moves nothing")
    func deplacementRefuse() {
        var order = SessionOrder()
        let outside = order.move(a, onto: c, within: [a, b])
        let ontoItself = order.move(a, onto: a, within: [a, b])
        #expect(!outside)
        #expect(!ontoItself)
        #expect(order.ids.isEmpty)
    }

    @Test("sessions that no longer exist are forgotten")
    func nettoyage() {
        var order = SessionOrder(ids: [a, b, c])
        order.prune(keeping: [a, c])
        #expect(order.ids == [a, c])
    }
}
