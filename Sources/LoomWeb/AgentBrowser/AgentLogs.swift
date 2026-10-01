import Foundation

/// Console levels, Playwright's semantics: a level includes the more severe ones.
public enum ConsoleLevel: String, Codable, CaseIterable, Equatable, Sendable {
    case error, warning, info, debug

    private var rank: Int {
        switch self {
        case .error: return 0
        case .warning: return 1
        case .info: return 2
        case .debug: return 3
        }
    }

    public func includes(_ other: ConsoleLevel) -> Bool { other.rank <= rank }
}

/// What a tab's pages logged, newest kept (pure). A main-frame navigation
/// starts a new generation: by default the agent reads the current page only.
public struct ConsoleLog: Sendable {
    public struct Entry: Equatable, Sendable {
        public var sequence: Int
        public var level: ConsoleLevel
        public var text: String
        public var location: String
        public var generation: Int
    }

    public let capacity: Int
    public private(set) var entries: [Entry] = []
    public private(set) var generation = 0
    private var sequence = 0
    public static let maxText = 2_000

    public init(capacity: Int = 1_000) {
        self.capacity = capacity
    }

    public mutating func append(level: ConsoleLevel, text: String, location: String = "") {
        sequence += 1
        entries.append(Entry(sequence: sequence, level: level, text: String(text.prefix(Self.maxText)),
                             location: String(location.prefix(300)), generation: generation))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    public mutating func navigationCommitted() { generation += 1 }

    public func messages(level: ConsoleLevel, all: Bool) -> [Entry] {
        entries.filter { level.includes($0.level) && (all || $0.generation == generation) }
    }

    /// The current page's errors and warnings, for `### Page`.
    public var counts: (errors: Int, warnings: Int) {
        let current = entries.filter { $0.generation == generation }
        return (current.filter { $0.level == .error }.count, current.filter { $0.level == .warning }.count)
    }

    /// `[ERROR] text @ location`, newest kept within `limit` characters.
    public func render(level: ConsoleLevel, all: Bool, limit: Int) -> String {
        let lines = messages(level: level, all: all).map { entry in
            "[\(entry.level.rawValue.uppercased())] \(entry.text)" + (entry.location.isEmpty ? "" : " @ \(entry.location)")
        }
        return Self.newestWithin(lines, limit: limit, empty: "No console messages.", unit: "messages")
    }

    static func newestWithin(_ lines: [String], limit: Int, empty: String, unit: String) -> String {
        guard !lines.isEmpty else { return empty }
        var kept: [String] = []
        var used = 0
        for line in lines.reversed() {
            if used + line.count + 1 > limit, !kept.isEmpty { break }
            kept.append(line)
            used += line.count + 1
        }
        let omitted = lines.count - kept.count
        let body = kept.reversed().joined(separator: "\n")
        return omitted > 0 ? "(\(omitted) earlier \(unit) omitted)\n" + body : body
    }
}

/// The requests a tab's pages made: the main documents (from the navigation
/// responses) and fetch/XHR (from the page hook), with their outcome.
public struct NetworkLog: Sendable {
    public enum Kind: String, Sendable { case document, fetch, xhr }

    public struct Entry: Equatable, Sendable {
        public var key: String
        public var sequence: Int
        public var kind: Kind
        public var method: String
        public var url: String
        public var status: Int?
        public var error: String?
        public var durationMs: Int?
        public var generation: Int

        public var isPending: Bool { status == nil && error == nil }
    }

    public let capacity: Int
    public private(set) var entries: [Entry] = []
    public private(set) var generation = 0
    private var sequence = 0

    public init(capacity: Int = 500) {
        self.capacity = capacity
    }

    public var lastSequence: Int { sequence }

    public mutating func started(key: String, kind: Kind, method: String, url: String) {
        sequence += 1
        entries.append(Entry(key: key, sequence: sequence, kind: kind, method: String(method.prefix(16)),
                             url: String(url.prefix(500)), generation: generation))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    public mutating func finished(key: String, status: Int?, error: String?, durationMs: Int?) {
        guard let index = entries.lastIndex(where: { $0.key == key && $0.isPending }) else { return }
        entries[index].status = status
        entries[index].error = error.map { String($0.prefix(300)) }
        entries[index].durationMs = durationMs
    }

    /// The main document's answer, from the navigation response.
    public mutating func document(url: String, status: Int) {
        started(key: "document#\(sequence + 1)", kind: .document, method: "GET", url: url)
        entries[entries.count - 1].status = status
    }

    public mutating func navigationCommitted() {
        generation += 1
        // What the old page left in flight will never answer to anyone.
        for index in entries.indices where entries[index].isPending && entries[index].kind != .document {
            entries[index].error = "abandoned by navigation"
        }
    }

    /// Requests of the current page still waiting, started after `sequence`.
    public func inFlight(after sequence: Int = 0) -> Int {
        entries.filter { $0.isPending && $0.sequence > sequence && $0.generation == generation }.count
    }

    public func render(filter: String?, limit: Int) -> String {
        let needle = filter?.lowercased()
        let lines = entries
            .filter { $0.generation == generation }
            .filter { needle == nil || needle!.isEmpty || $0.url.lowercased().contains(needle!) }
            .map { entry -> String in
                let outcome: String
                if let status = entry.status { outcome = "[\(status)]" }
                else if let error = entry.error { outcome = "[FAILED] \(error)" }
                else { outcome = "[pending]" }
                let duration = entry.durationMs.map { " (\($0) ms)" } ?? ""
                return "[\(entry.method)] \(entry.url) => \(outcome)\(duration)"
            }
        return ConsoleLog.newestWithin(lines, limit: limit, empty: "No requests since the page loaded.",
                                       unit: "requests")
    }
}

/// One message of the page hook, validated: anything else is dropped. The
/// page can post to the channel itself — nothing here is trusted beyond its
/// shape and size.
public enum AgentHookMessage: Equatable, Sendable {
    case console(level: ConsoleLevel, text: String, location: String)
    case request(id: Int, kind: NetworkLog.Kind, method: String, url: String)
    case response(id: Int, status: Int?, error: String?, durationMs: Int?)
    case dropped(Int)

    public static func parse(_ body: Any) -> AgentHookMessage? {
        guard let fields = body as? [String: Any], let type = fields["t"] as? String else { return nil }
        func string(_ key: String, max: Int) -> String? {
            (fields[key] as? String).map { String($0.prefix(max)) }
        }
        func int(_ key: String) -> Int? {
            if let value = fields[key] as? Int { return value }
            if let value = fields[key] as? Double, value.isFinite, abs(value) < 1e12 { return Int(value) }
            return nil
        }
        switch type {
        case "console":
            guard let raw = string("level", max: 16), let level = ConsoleLevel(rawValue: raw),
                  let text = string("text", max: ConsoleLog.maxText) else { return nil }
            return .console(level: level, text: text, location: string("loc", max: 300) ?? "")
        case "req":
            guard let id = int("id"), let raw = string("kind", max: 8), let kind = NetworkLog.Kind(rawValue: raw),
                  kind != .document, let url = string("url", max: 500) else { return nil }
            return .request(id: id, kind: kind, method: string("method", max: 16) ?? "GET", url: url)
        case "res":
            guard let id = int("id") else { return nil }
            return .response(id: id, status: int("status"), error: string("error", max: 300), durationMs: int("ms"))
        case "dropped":
            return int("n").map { .dropped(max(0, $0)) }
        default:
            return nil
        }
    }
}

/// Loom's own limit on what a page may post: the page's script can bypass
/// the hook's bucket, never this one (pure: the clock is passed in).
public struct AgentRateLimiter: Sendable {
    public let perSecond: Double
    public let burst: Double
    private var tokens: Double
    private var last: Double?

    public init(perSecond: Double = 300, burst: Double = 300) {
        self.perSecond = perSecond
        self.burst = burst
        tokens = burst
    }

    public mutating func admit(at time: Double) -> Bool {
        if let last { tokens = min(burst, tokens + (time - last) * perSecond) }
        last = time
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
}
