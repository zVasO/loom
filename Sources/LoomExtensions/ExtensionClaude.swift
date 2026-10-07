import Foundation

// `claude.complete` (ADR-0015): an extension asks Claude for text, with the
// user's Claude Code account. The app runs `claude -p` with no tools, no MCP
// server, no hook, in an empty folder; here are the checks before it does, and
// the shapes in and out.

/// `claude.complete`'s parameters, as the page sends them.
public struct BridgeClaudeCompleteParams: Codable, Equatable, Sendable {
    public var prompt: String
    /// Replaces Claude Code's own system prompt for this run.
    public var system: String?
    /// `haiku`, `sonnet` or `opus`; absent is the user's default model.
    public var model: String?
    public var timeoutMs: Double?

    public init(prompt: String, system: String? = nil, model: String? = nil, timeoutMs: Double? = nil) {
        self.prompt = prompt
        self.system = system
        self.model = model
        self.timeoutMs = timeoutMs
    }

    public static let maxPromptLength = 100_000
    public static let maxSystemLength = 10_000
    public static let models: Set<String> = ["haiku", "sonnet", "opus"]
    public static let defaultTimeout: TimeInterval = 120
    public static let minimumTimeout: TimeInterval = 10
    public static let maximumTimeout: TimeInterval = 300

    /// The checked request: a prompt that is not empty and not too long, a
    /// known model alias, a timeout clamped to 10 s … 5 min.
    public func validated() throws -> ClaudeCompletionRequest {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BridgeError(.invalidParams, "claude.complete needs a prompt")
        }
        guard prompt.count <= Self.maxPromptLength else {
            throw BridgeError(.tooLarge, "the prompt is over \(Self.maxPromptLength) characters")
        }
        if let system, system.count > Self.maxSystemLength {
            throw BridgeError(.tooLarge, "the system prompt is over \(Self.maxSystemLength) characters")
        }
        if let model, !Self.models.contains(model) {
            throw BridgeError(.invalidParams, "model is \"haiku\", \"sonnet\" or \"opus\"")
        }
        var timeout = Self.defaultTimeout
        if let timeoutMs {
            guard timeoutMs.isFinite else { throw BridgeError(.invalidParams, "timeoutMs is milliseconds") }
            timeout = min(max(timeoutMs / 1000, Self.minimumTimeout), Self.maximumTimeout)
        }
        let trimmedSystem = system?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ClaudeCompletionRequest(prompt: prompt,
                                       system: trimmedSystem?.isEmpty == false ? system : nil,
                                       model: model, timeout: timeout)
    }
}

/// What the app is asked to run, already checked.
public struct ClaudeCompletionRequest: Equatable, Sendable {
    public var prompt: String
    public var system: String?
    public var model: String?
    public var timeout: TimeInterval

    public init(prompt: String, system: String? = nil, model: String? = nil,
                timeout: TimeInterval = BridgeClaudeCompleteParams.defaultTimeout) {
        self.prompt = prompt
        self.system = system
        self.model = model
        self.timeout = timeout
    }
}

/// `claude.complete`'s answer.
public struct BridgeClaudeCompletion: Codable, Equatable, Sendable {
    public var text: String
    /// The model that answered, as claude names it.
    public var model: String?
    /// What the run cost, as claude counts it — on the user's plan.
    public var costUsd: Double?
    public var durationMs: Int
    /// The text was cut to `maxTextLength`.
    public var truncated: Bool

    public init(text: String, model: String? = nil, costUsd: Double? = nil,
                durationMs: Int, truncated: Bool = false) {
        self.text = text
        self.model = model
        self.costUsd = costUsd
        self.durationMs = durationMs
        self.truncated = truncated
    }

    public static let maxTextLength = 100_000
}

/// How many runs an extension may start in an hour — a page in a loop must
/// not spend the user's plan behind their back.
public struct ClaudeCompletionBudget: Sendable, Equatable {
    public static let maxPerHour = 30
    public static let window: TimeInterval = 3600

    private var starts: [Date] = []

    public init() {}

    /// Counts a run starting at `now`, or refuses it when the last hour
    /// already holds `maxPerHour`.
    public mutating func admit(now: Date) -> Bool {
        starts.removeAll { now.timeIntervalSince($0) >= Self.window }
        guard starts.count < Self.maxPerHour else { return false }
        starts.append(now)
        return true
    }
}
