import Foundation

/// A change an agent made through Loom's API (ADR-0020): a workflow, a
/// block, an expert, a schedule it created or edited. It stays inert — never
/// run, never scheduled — until the person validates it; until then what
/// counts is `previous`, the version they validated (nil for a creation).
public struct AgentProposal<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    /// Who proposed it: the session's title, or "loom CLI".
    public var by: String
    /// The proposing session, when a session did.
    public var sessionID: String?
    public var at: Date
    /// Boxed: a value holds its proposal, which holds the previous value.
    private var box: [Value]

    public var previous: Value? {
        get { box.first }
        set { box = newValue.map { [$0] } ?? [] }
    }

    public init(by: String, sessionID: String? = nil, at: Date = Date(), previous: Value? = nil) {
        self.by = by
        self.sessionID = sessionID
        self.at = at
        self.box = previous.map { [$0] } ?? []
    }

    enum CodingKeys: String, CodingKey { case by, sessionID, at, previous }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(by: try c.decodeIfPresent(String.self, forKey: .by) ?? "an agent",
                  sessionID: try c.decodeIfPresent(String.self, forKey: .sessionID),
                  at: try c.decodeIfPresent(Date.self, forKey: .at) ?? Date(),
                  previous: try c.decodeIfPresent(Value.self, forKey: .previous))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(by, forKey: .by)
        try c.encodeIfPresent(sessionID, forKey: .sessionID)
        try c.encode(at, forKey: .at)
        try c.encodeIfPresent(previous, forKey: .previous)
    }
}

extension AgentProposal: Hashable where Value: Hashable {}

/// What an agent may propose: the rules of a proposal, the same for each kind.
public protocol Proposable: Codable, Equatable, Sendable {
    var proposal: AgentProposal<Self>? { get set }
}

extension Proposable {
    public var isProposed: Bool { proposal != nil }

    /// What counts now: itself once validated, else the version validated
    /// before the agent's change — nil for something the agent created.
    public var accepted: Self? {
        guard let proposal else { return self }
        guard var previous = proposal.previous else { return nil }
        previous.proposal = nil
        return previous
    }

    /// The person validates it: the agent's version counts from now on.
    public func validated() -> Self {
        var copy = self
        copy.proposal = nil
        return copy
    }

    /// The person turns it down: the version before, or nothing (delete it).
    public func reverted() -> Self? { accepted }

    /// `new`, as an agent's proposal over `existing`: the version validated
    /// before the agent's FIRST change stays the one to go back to.
    public static func proposing(_ new: Self, over existing: Self?, by: String, sessionID: String? = nil,
                                 at date: Date = Date()) -> Self {
        var result = new
        let previous: Self?
        if let existing {
            previous = existing.isProposed ? existing.proposal?.previous : existing.validated()
        } else {
            previous = nil
        }
        result.proposal = AgentProposal(by: by, sessionID: sessionID, at: date, previous: previous)
        return result
    }
}
