import Foundation
import LoomAPI

/// Turns successive snapshots of the sessions into the events a page hears:
/// one `session.stateChanged` per session whose state moved, then one
/// `sessions.changed` carrying the whole list whenever anything differs —
/// a title, a badge, a session that came or went. The first snapshot is a
/// baseline and says nothing: a page asks `sessions.list` when it loads.
public struct SessionChangeDetector: Sendable {
    private var last: [String: APISession]?

    public init() {}

    public mutating func update(_ snapshot: [APISession]) -> [BridgeEvent] {
        var byID: [String: APISession] = [:]
        for session in snapshot { byID[session.id] = session }
        defer { last = byID }
        guard let last else { return [] }
        guard last != byID else { return [] }
        var events: [BridgeEvent] = []
        for session in snapshot {
            let previous = last[session.id]?.state
            if previous != session.state {
                events.append(.sessionStateChanged(sessionId: session.id, state: session.state,
                                                   previous: previous))
            }
        }
        events.append(.sessionsChanged(snapshot))
        return events
    }
}
