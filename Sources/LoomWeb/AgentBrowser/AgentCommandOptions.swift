import Foundation
import LoomAPI

/// What an action's answer shows of the page afterwards. `full` is Playwright
/// MCP's answer — the new snapshot; `none` leaves it out, for an agent that
/// chains actions on refs it already has: a much shorter answer, sooner.
public enum SnapshotMode: String, Sendable, Equatable, CaseIterable {
    case full, none
}

/// How a command answers, apart from what it does — so a command stays the
/// same value whatever the agent wants to read back.
public struct AgentCommandOptions: Sendable, Equatable {
    public var snapshot: SnapshotMode

    public init(snapshot: SnapshotMode = .full) {
        self.snapshot = snapshot
    }
}

extension AgentCommandOptions {

    /// The options a browser method's parameters ask for. `snapshot` is read
    /// on the methods that answer a snapshot only: anywhere else it is an
    /// `invalidParams` the agent can fix.
    public init(method: APIMethod, params: JSONValue) throws {
        self.init()
        guard let raw = params["snapshot"], raw != .null else { return }
        guard method.answersSnapshot else {
            throw APIError(code: .invalidParams,
                           message: "snapshot: \(method.rawValue) answers no snapshot")
        }
        guard let value = raw.stringValue, let mode = SnapshotMode(rawValue: value) else {
            throw APIError(code: .invalidParams, message: "snapshot is full or none")
        }
        snapshot = mode
    }
}
