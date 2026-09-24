import Foundation

/// The order the user gave the session cards of the sidebar by dragging
/// them — a display preference, one rank per session across every project.
///
/// Sessions the user never placed keep the slot their natural order gives
/// them (live ones first, in launch order, then dormant ones newest first):
/// only the ranked ones are permuted among the slots they occupy. A new
/// session therefore appears where it always did, and a resumed one keeps
/// the place the user gave it instead of jumping to the end of the live block.
public struct SessionOrder: Equatable, Sendable {
    public private(set) var ids: [SessionID]

    public init(ids: [SessionID] = []) {
        self.ids = ids
    }

    /// `items` in the user's order. Stable; a no-op without any rank.
    public func sorted<T>(_ items: [T], id: (T) -> SessionID) -> [T] {
        guard !ids.isEmpty else { return items }
        let rank = Dictionary(ids.enumerated().map { ($1, $0) }) { first, _ in first }
        let rankedSlots = items.indices.filter { rank[id(items[$0])] != nil }
        guard rankedSlots.count > 1 else { return items }
        let rankedItems = rankedSlots.map { items[$0] }
            .sorted { (rank[id($0)] ?? .max) < (rank[id($1)] ?? .max) }
        var result = items
        for (slot, item) in zip(rankedSlots, rankedItems) { result[slot] = item }
        return result
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
