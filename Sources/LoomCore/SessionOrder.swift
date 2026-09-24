import Foundation

/// The order the user gave the session cards of the sidebar by dragging
/// them — a display preference, one rank per session across every project.
///
/// The order must read the same before and after a restart, and a restart
/// turns every live session into a dormant one: nothing may depend on which
/// is which. Sessions the user never placed therefore come first, newest
/// creation first — a date that never changes — so a new session appears on
/// top of its group; the placed ones follow, in the order the user gave them.
public struct SessionOrder: Equatable, Sendable {
    public private(set) var ids: [SessionID]

    public init(ids: [SessionID] = []) {
        self.ids = ids
    }

    /// `items` in the user's order: the unplaced ones first, newest
    /// `createdAt` first, then the placed ones by rank. Independent of the
    /// input order; ties keep it.
    public func sorted<T>(_ items: [T], id: (T) -> SessionID, createdAt: (T) -> Date) -> [T] {
        let rank = Dictionary(ids.enumerated().map { ($1, $0) }) { first, _ in first }
        let indexed = Array(items.enumerated())
        let unplaced = indexed.filter { rank[id($0.element)] == nil }
            .sorted { lhs, rhs in
                let (l, r) = (createdAt(lhs.element), createdAt(rhs.element))
                return l == r ? lhs.offset < rhs.offset : l > r
            }
        let placed = indexed.filter { rank[id($0.element)] != nil }
            .sorted { (rank[id($0.element)] ?? .max) < (rank[id($1.element)] ?? .max) }
        return (unplaced + placed).map(\.element)
    }

    /// Moves `dragged` onto `target`'s place inside `visible` — the cards of
    /// ONE group, in the order they are displayed. Dragging down lands after
    /// the target, dragging up before it, as the card under the pointer.
    /// The whole group becomes ranked; other groups' ranks are untouched.
    /// `false` when either card is not in the group: nothing moves.
    @discardableResult
    public mutating func move(_ dragged: SessionID, onto target: SessionID,
                              within visible: [SessionID]) -> Bool {
        guard dragged != target,
              let from = visible.firstIndex(of: dragged),
              let to = visible.firstIndex(of: target) else { return false }
        var order = visible
        let moving = order.remove(at: from)
        order.insert(moving, at: to)
        let group = Set(visible)
        ids = ids.filter { !group.contains($0) } + order
        return true
    }

    /// Forgets the sessions that no longer exist.
    public mutating func prune(keeping known: Set<SessionID>) {
        ids.removeAll { !known.contains($0) }
    }
}
